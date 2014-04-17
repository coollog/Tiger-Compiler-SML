structure InterferenceGraph = FuncGraph(Temp.TempOrd)

signature COLOR = 
sig
	structure Frame : FRAME

	type allocation = Frame.register Temp.table 

	(*initial is pre-colored nodes due to calling conventions*)
	(*spillCost evaluates how much it costs to spill a variable, naive approach returns 1 for every temp*)
	(*registers are all the registers available in a machine*)
	(*Temp.temp list in the output is a spill list*)
	val color: {interference: Liveness.igraph,
				initial: allocation,
				spillCost: Liveness.igraphNode InterferenceGraph.node -> int,
				registers: Frame.register list}
				-> allocation * Temp.temp list
				}
end

structure Color :> COLOR =
struct
	structure IG = InterferenceGraph
	structure F = MipsFrame
	structure Te = Temp
	structure Table = Te.Table
	structure L = Liveness

	structure Stack = 
	struct
		type 'a stack = 'a list
		val empty = []
		val push = op ::
		fun pop [] = (NONE, [])
		  | pop (tos::rest) = (SOME tos, rest)
	end

	val spilled = ref false

  	structure Set = Temp.Set

	fun color ({L.IGRAPH {graph=interference, moves=moves}, initial, spillCost, registers}) =
		let
		    val coloredNodes = ref Set.empty (* The nodes we have colored so far*)
		  	val regColorMap = ref initial : allocation ref
		    val okColors = ref palette
		    val nodes = IG.nodes(interference) (* List of nodes*)

		    fun addNodeId node lst = IG.getNodeID(node)::lst

		    val nodeList = foldl addNodeId [] nodes (* List of node ids. All node arguments reference this list, so they are id's*)

		    val numRegs = 27 (*should get this information from registers parameter that's passed in*)

		    fun getDegree node = IG.outDegree(node)

			fun remove (elem myList) = List.filter (fn x => x <> elem) myList;

			fun nodeMoves(node, activeMoves, workListMoves, moveList) = (* Where does moveList come from??? *)
				let
					val allMoves = Set.union(activeMoves, workListMoves)
				in 
					Set.intersection(moveList(node), allMoves)
				end

			fun moveRelated(node, nodeMoves) = nodeMoves(node) <> []

		    fun makeWorkList =
		    	let
		    		fun addNodeToList(currentNode, (simplifyWorkList, freezeWorkList)) =
		    			let
		    				val preColored = Table.look(initial, IG.getNodeID(currentNode)) (*Check if node has been precolored*)
		    			in
		    				case preColored of 
		    					SOME(color) => (simplifyWorkList, spillWorkList) (*Do not color if node has been precolored*)
		    				  | NONE => if moveRelated(currentNode) then (simplifyWorkList, currentNode::freezeWorkList)
		    						   else (currentNode::simplifyWorkList, freezeWorkList)
		    			end
		    	in
		    		foldl addNodeToList ([],[]) nodeList
		    	end

		    val lists = makeWorkList()
		    val simplifyWorkList = #1 lists
		    val freezeWorkList = #2 lists

		    (* Simplifies a node, removes it from the graph*)
		    fun simplify(node, selectStack, simplifyWorkList, spillWorkList, interference) = 
		    	let 
		    		val adjacentNodes = IG.adj(interference', node) (*i think these nodes will retain the original degree...hmm*)
		    		val selectStack' = Stack.push(node, selectStack)
		    		val simplifyWorkList' = remove(node, simplifyWorkList)
		    		val interference' = IG.remove(interference, node) (* Remove the node from the graph*)
		    		val (simplifyWorkList', spillWorkList) = foldl decrementDegree (simplifyWorkList', spillWorkList) adjacentNodes
		    	in
		    		(selectStack, simplifyWorklist, spillWorkList, interference')
		    	end

		    fun runSimplify([],selectStack,interference) = selectStack
		      | runSimplify(node::rest,selectStack,interference) =
		        let 
		        	val (selectStack, simplifyWorklist, spillWorkList, interference) = simplify(node, selectStack, simplifyWorklist, interference)
		        in 
		        	runSimplify(rest, selectStack, interference)
		        end

		    val selectStack = runSimplify(simplifyWorklist, [], interference)

		    fun enableMoves(nodes, activeMoves, workListMoves) =
		    	let 
		    		fun enable node (activeMoves, workListMoves) =
		    			let
		    				val moves = nodeMoves(node)
		    				val result = foldl processMove (activeMoves, workListMoves) moves
		    			in
		    				(#1 result, #2 result)
		    			end
		    	in
		    		foldl enable (activeMoves, workListMoves) nodes
		    	end

		    fun processMove(move, (activeMoves, workListMoves)) =
		    	if SET.member(activeMoves, move)
		    	then (SET.add(activeMoves, move), SET.add(workListMoves, move))

		     (* Do we even need this if were not doing spill??? *)
		    fun decrementDegree(node, (simplifyWorkList, spillWorkList)) =
		    	let
		    		val d = IG.degree(node)
		    		(* No need to decrement node degree *)
		    	in
		    		if d < numRegs (* Shouldnt this be an equal? *)
		    		then (node::simplifyWorkList, remove(node, spillWorkList)) (*Move node from spill list to simplify list*)
		    		else (simplifyWorkList, spillWorkList)
		    	end

		    fun selectBestNode(node, bestSoFar) = 
		    		if (spillCost(node)<spillCost(bestSoFar)) (* Heuristic for selecting best node to spill *)
		    		then node
		    		else bestSoFar

		    fun selectSpill(simplifyWorkList, spillWorkList) =
		    	let 
		    		val head = hd spillWorkList
		    		val spillNode = foldl selectBestNode head spillWorkList 
		    		val spillWorkList' = remove(spillNode, spillWorkList)
		    		val simplifyWorkList' = spillNode::simplifyWorkList
		    		(*i think we remove this spill node from the igraph and restart all over from the beginning*)
		    	in 
		    		(simplifyWorkList', spillWorkList')
		    	end	

		    fun filterColors(node, initial) =
				let
					val color = Table.look(initial, IG.getNodeID(node))
				in
					remove(color, initial)
				end					

		 	fun assignColors(selectStack, okColors) = 
		 		let 
			 		fun assignColor(node, (initial, coloredNodes)) =
			 			let
			 				val okColors = List.tabulate(numRegs, fn x => x); (* Generates list [0,1,2,..numRegs]*)
	 						val adjacent = IG.adj node
	 						val okColors' = foldl filterColors okColors adjacent
	 						val color = hd okColors' (* Just take the first available color to color our node *)
	 						val coloredNodes' = node::coloredNodes
	 						val colorTable = Table.enter(initial, node, color)
		 				in
		 					(colorTable, coloredNodes')
		 				end
			 	in 
			 		foldl assignColor (initial, []) selectStack
		 		end
		in
			body
		end

end