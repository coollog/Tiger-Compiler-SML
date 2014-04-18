signature COLOR = 
sig

	type allocation = MipsFrame.register Temp.table 

	(*initial is pre-colored nodes due to calling conventions*)
	(*spillCost evaluates how much it costs to spill a variable, naive approach returns 1 for every temp*)
	(*registers are all the registers available in a machine*)
	(*Temp.temp list in the output is a spill list*)
	val color: {interference: Liveness.igraph,
				initial: allocation,
				spillCost: Liveness.igraphNode IGraph.node -> int,
				registers: MipsFrame.register list}
				-> allocation * Temp.temp list
end

structure Color :> COLOR =
struct
	structure IG = IGraph
	structure Te = Temp
	structure Table = Te.Table
	structure L = Liveness
  	structure Set = Te.Set

	type allocation = MipsFrame.register Te.table 

	structure Stack = 
	struct
		type 'a stack = 'a list
		val empty = []
		val push = op ::
		fun pop [] = (NONE, [])
		  | pop (tos::rest) = (SOME tos, rest)
	end

	val spilled = ref false


	fun removeFromList (elem, myList) = List.filter (fn x => x <> elem) myList;

	fun color ({interference=L.IGRAPH {graph=interference, moves=moves}, initial=initial, spillCost=spillCost, registers=registers}) =
		let
		    val movePairs = ref moves

		 	val coalesceSuccess = ref false
		 	val unfreezeSuccess = ref false

		    val numRegs = 27 (*should get this information from registers parameter that's passed in. E.g. List.length registers*)

		    fun allMoveNodeIDs() = 
		    	let
		    		fun oneMovePair((oneNode, otherNode), currSet) =
		    			Set.add(Set.add(currSet, oneNode), otherNode)
		    	in
		    		foldl oneMovePair Set.empty (!movePairs)
		    	end

		    fun lookForSimpliable(ig, nodeIDList) =
		    	let
		    		fun addNodeToList(currentNodeID, (simplifyWorkList, freezeWorkList, nonSimplifiable)) =
		    			let
		    				val currentNode = IG.getNode(ig, currentNodeID)
		    				val preColored = Table.look(initial, currentNodeID)
		    				val moveNodeSet = allMoveNodeIDs()
		    			in
		    				case preColored of 
		    					SOME(color) => (simplifyWorkList, freezeWorkList, nonSimplifiable)
		    				  | NONE => if Set.member(moveNodeSet, currentNodeID)
		    				  			then (simplifyWorkList, currentNodeID::freezeWorkList, nonSimplifiable)
		    						    else (if IG.outDegree(currentNode)< numRegs
		    						    	  then (currentNodeID::simplifyWorkList, freezeWorkList, nonSimplifiable)
		    						    	  else (simplifyWorkList, freezeWorkList, currentNodeID::nonSimplifiable))
		    			end
		    	in
		    		foldl addNodeToList ([], [], []) nodeIDList
		    	end

		    (* simplify all nodes in the simplifyWorkList, returns the updated stack, lists and graph*)
		    fun simplify(selectStack, ig, simList) = 
		    	let 
		    		fun simplifyOneNode (nodeID, (stack, g)) =
		    			(Stack.push(nodeID, stack), IG.removeNode'(g, nodeID))
		    	in
		    		foldr simplifyOneNode (selectStack, ig) simList
		    	end

		    (*look for possible coalescing and perform it, returns the new graph*)
		    fun coalesceAndReturnNewGraph(ig) = 
		    	let
		    		fun briggs((node1ID, node2ID), g) = 
		    			let
		    				val node1 = IG.getNode(g, node1ID)
		    				val node2 = IG.getNode(g, node2ID)

		    				(*num of neighbors with significant degree after merge*)
		    				fun significantDegree(n) = 
		    					let
		    						val neighbors = IG.succs' g n
		    						val succNodes = 
		    							List.filter (fn nn => (not (IG.getNodeID nn = IG.getNodeID node1))
		    											andalso (not (IG.getNodeID nn = IG.getNodeID node2)))
		    										neighbors

		    						fun isSignificant(neighborNode) =
		    							let
		    								val adjToBoth = 
		    									if IG.isAdjacent(neighborNode, node1) andalso IG.isAdjacent(neighborNode, node2)
		    									then 1
		    									else 0
		    							in
		    								if IG.outDegree(neighborNode)-adjToBoth < numRegs
		    								then false
		    								else true
		    							end
		    					in
		    						List.length(List.filter (fn b => b) (map isSignificant succNodes))
		    					end

		    				val totalDegree = significantDegree(node1) + significantDegree(node2)
		    			in
		    				if totalDegree < numRegs
		    				then (movePairs := removeFromList((node1ID, node2ID), (!movePairs));
		    					  coalesceSuccess := true;
		    					  mergeNodes(g, node1, node2))
		    				else g
		    			end

		    		val newIG = foldr briggs ig (!movePairs)
		    	in
		    		(!coalesceSuccess, newIG)
		    	end

		    (*helper function for Briggs Coalescing*)
		    and mergeNodes(ig, n1, n2) = 
		    	let
		    		val node1Succs = IG.succs(n1)
		    		fun addEdge(succID, g) =
		    			if succID = IG.getNodeID n2
		    			then g
		    			else IG.doubleEdge(g, IG.getNodeID n2, succID)
		    		val addedG = foldl addEdge ig node1Succs
		    	in
		    		IG.remove(addedG, n1)
		    	end

		    (*subroutine for unfreeze procedure*)
		    fun bestMoveNodeToFreeze(ig) = 
		    	let
		    		val moveNodeIDs = Set.listItems(allMoveNodeIDs())
		    		fun compareDegree(currNodeID, bestNodeID) = 
		    			if IG.outDegree(IG.getNode(ig, currNodeID)) < IG.outDegree(IG.getNode(ig, bestNodeID))
		    			then currNodeID
		    			else bestNodeID
		    	in
		    		(unfreezeSuccess := List.length(moveNodeIDs) > 0;
		    		foldr compareDegree (hd moveNodeIDs) moveNodeIDs)
		    	end

		    (*turn move edges associated with this node into normal edges, should restart from simplify after this step*)
		    fun unfreezeMove(moveNodeID) =
		    	let 
		    		fun noHaveThisNode((n1, n2)) =
		    			if (n1 = moveNodeID orelse n2 = moveNodeID)
		    			then true
		    			else false
		    	in
		    		if !unfreezeSuccess = true
		    		then (movePairs := List.filter noHaveThisNode (!movePairs); true)
		    		else false
		    	end


		    (*we should use 1/IG.outDegree(node) as our spillCost function, so that we pick the highest degree node to spill*)
		    fun selectBestSpillNode(nodeID, (g, bestSoFarID)) = 
		    		if spillCost(IG.getNode (g,nodeID))<spillCost(IG.getNode (g, bestSoFarID))
		    		then (g, nodeID)
		    		else (g, bestSoFarID)

		    fun selectSpill(ig, selectStack, spillWorkList) =
		    	let 
		    		val head = hd spillWorkList
		    		val (_, spillNodeID) = foldl selectBestSpillNode (ig, head) spillWorkList
		    		val selectStack' = Stack.push(spillNodeID, selectStack)
		    		val ig' = IG.removeNode'(ig, spillNodeID)
		    	in 
		    		(if List.length(spillWorkList) <= 0
		 					 then ErrorMsg.impossible "No more node to select for potential spill...but algorithm doesn't end???"
		 					 else ();
		    		(ig', selectStack'))
		    	end	

		    fun filterColors(nodeID, (alloc, avaiRegs)) =
				let
					val register = Table.look(alloc, nodeID)
				in
					case register of
						SOME(r) => (alloc, removeFromList(r, avaiRegs))
						| NONE => (alloc, avaiRegs)
				end					

			(*this method uses a coulpe global variables: initial, registers*)
		 	fun assignColors(oldIG, selectStack) = 
		 		let 
			 		fun assignColor(nodeID, alloc) =
			 			let
			 				(*val okColors = List.tabulate(numRegs, fn x => x); (* Generates list [0,1,2,..numRegs]*)*)
			 				val okColors = registers
	 						val adjacent = IG.adj (IG.getNode (oldIG, nodeID))
	 						val (_, okColors') = foldl filterColors (alloc, okColors) adjacent
	 						val color = hd okColors' (* Just take the first available color to color our node *)
	 						val addedAlloc = Table.enter(alloc, nodeID, color)
		 				in
		 					(if List.length(okColors') <= 0
		 					 then ErrorMsg.impossible "No color assignable for a temp node, actual spill occurs..."
		 					 else ();
		 					 addedAlloc)
		 				end
			 	in 
			 		foldl assignColor initial selectStack
		 		end

		 	(*main loop*)
		 	fun runRegAlloc(ig, selectStack) = 
		 		let
				    val nodes = IG.nodes(ig) (* List of nodes*)
				    val nodeIDList = map IG.getNodeID nodes (* List of node ids *)

				    val (simplifyWorkList, freezeWorkList, nonSimplifiable) = lookForSimpliable(ig, nodeIDList)
				    val graphEmpty = if List.length(freezeWorkList)+List.length(nonSimplifiable) = 0 then true else false
				    val simplifyDidWork = List.length(simplifyWorkList) > 0
				    val (updatedStack, updatedIG) = simplify(selectStack, ig, simplifyWorkList)
				in
					case simplifyDidWork of 
						true => runRegAlloc(updatedIG, updatedStack)
						| false =>
							(case graphEmpty of 
							true => assignColors(interference, updatedStack)
							| false => (case coalesceAndReturnNewGraph(updatedIG) of 
										(true, newIG) => (coalesceSuccess := false;
														  runRegAlloc(newIG, updatedStack))
										| (false, newIG) => (case unfreezeMove(bestMoveNodeToFreeze(newIG)) of 
															 true => (unfreezeSuccess := false;
															 		  runRegAlloc(newIG, updatedStack))
															 | false => (case selectSpill(newIG, updatedStack, nonSimplifiable) of 
															 			(ig', stack') => runRegAlloc(ig', stack')
															 			)
															 )
										)
							)
				end
		in
			(runRegAlloc(interference, Stack.empty), [])
		end
end
