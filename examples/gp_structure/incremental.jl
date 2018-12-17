include("shared.jl")

"""
Data type used in return value of the production kernel (V).
"""
struct NodeTypeAndXs
    node_type::Int
    xs::Vector{Float64}
end

"""
Singleton type representing difference in node type and xs (DV)

Contains no information (a difference is always assumed)
"""
struct NodeTypeAndXsDiff end
Gen.isnodiff(::NodeTypeAndXsDiff) = false


"""
Data type for the return value of the aggregation kernel (W)
"""
struct CovFnAndMatrix
    node::Node
    cov_matrix::Matrix{Float64}
end

"""
Singleton type representing difference in return value of the aggregation kernel (DW)

Contains no information (a difference is always assumed)
"""
struct CovFnAndMatrixDiff end
Gen.isnodiff(::CovFnAndMatrixDiff) = false

const production_retdiff = RecurseProductionRetDiff{NodeTypeAndXsDiff,Nothing}(
    NodeTypeAndXsDiff(), # no information given about change in 'v' (it is assumed to change)
    Dict{Int,Nothing}()) # empty dictionary indicates that no inputs to children ('u') changed

@gen function production_kernel(xs::Vector{Float64})
    node_type = @addr(categorical(node_dist), :type)

    # verify that xs did not change
    @diff @assert @argdiff() == noargdiff

    # indicate that the xs passed to our children did not change
    # but that the node type might have changed
    @diff @retdiff(production_retdiff)

    # to be passed to the corresponding aggregation kernel application
    v = NodeTypeAndXs(node_type, xs)

    # elements to be passed to each child production kernel application
    num_children = node_type_to_num_children[node_type]
    us = fill(xs, num_children)

    return (v, us)
end

@gen function aggregation_kernel(node_type_and_xs::NodeTypeAndXs,
                                 child_outputs::Vector{CovFnAndMatrix})

    node_type::Int = node_type_and_xs.node_type
    xs::Vector{Float64} = node_type_and_xs.xs
    local node::Node
    local cov_matrix::Matrix{Float64}

    # constant kernel
    if node_type == CONSTANT
        @assert length(child_outputs) == 0
        param = @addr(uniform_continuous(0, 1), :param)
        node = Constant(param)
        cov_matrix = eval_cov_mat(node, xs)

    # linear kernel
    elseif node_type == LINEAR
        @assert length(child_outputs) == 0
        param = @addr(uniform_continuous(0, 1), :param)
        node = Linear(param)
        cov_matrix = eval_cov_mat(node, xs)

    # squared exponential kernel
    elseif node_type == SQUARED_EXP
        @assert length(child_outputs) == 0
        length_scale = 0.01 + @addr(uniform_continuous(0, 1), :length_scale)
        node = SquaredExponential(length_scale)
        cov_matrix = eval_cov_mat(node, xs)

    # periodic kernel
    elseif node_type == PERIODIC
        @assert length(child_outputs) == 0
        scale = 0.01 + @addr(uniform_continuous(0, 1), :scale)
        period = 0.01 + @addr(uniform_continuous(0, 1), :period)
        node = Periodic(scale, period)
        cov_matrix = eval_cov_mat(node, xs)

    # plus combinator
    elseif node_type == PLUS
        @assert length(child_outputs) == 2
        node = Plus(child_outputs[1].node, child_outputs[2].node)
        cov_matrix = child_outputs[1].cov_matrix .+ child_outputs[2].cov_matrix

    # times combinator
    elseif node_type == TIMES
        @assert length(child_outputs) == 2
        node = Times(child_outputs[1].node, child_outputs[2].node)
        cov_matrix = child_outputs[1].cov_matrix .* child_outputs[2].cov_matrix

    else
        error("unknown node type $node_type")
    end

    # don't provide any information about the change in return value
    @diff @retdiff(CovFnAndMatrixDiff())
    
    # to be passed to the parent aggregation kernel application
    w = CovFnAndMatrix(node, cov_matrix)

    return w
end

const covariance_prior = Recurse(
        production_kernel, aggregation_kernel,
        max_branch, # maximum number of children generated by production
        Vector{Float64}, # U (passed from production to its children)
        NodeTypeAndXs, # V (passed from production to aggregation)
        CovFnAndMatrix, # W (passed from aggregation to its parents, also Recurse's return type)
        NodeTypeAndXsDiff, # DV
        Nothing, # DU (there are never changes indicated, so 'du' values are never used)
        CovFnAndMatrixDiff) # DW

@gen function model(xs::Vector{Float64})

    # sample covariance matrix
    cov_fn_and_matrix = @addr(covariance_prior(xs, 1), :tree, noargdiff)

    # sample diagonal noise
    noise = @addr(gamma(1, 1), :noise) + 0.01

    # compute covariance matrix
    n = length(xs)
    cov_matrix = cov_fn_and_matrix.cov_matrix + Matrix(noise * LinearAlgebra.I, n, n)

    # sample from multivariate normal   
    @addr(mvnormal(zeros(n), cov_matrix), :ys)

    return cov_fn_and_matrix.node
end

@gen function subtree_proposal_recursive(cur::Int)
    
    # base address for production kernel application 'cur'
    prod_addr = (cur, Val(:production))

    # base address for aggregation kernel application 'cur'
    agg_addr = (cur, Val(:aggregation))
    
    # sample node type
    node_type = @addr(categorical(node_dist), (cur, Val(:production)) => :type)

    # constant kernel
    if node_type == CONSTANT
        @addr(uniform_continuous(0, 1), agg_addr => :param)

    # linear kernel
    elseif node_type == LINEAR
        @addr(uniform_continuous(0, 1), agg_addr => :param)

    # squared exponential kernel
    elseif node_type == SQUARED_EXP
        @addr(uniform_continuous(0, 1), agg_addr => :length_scale)

    # periodic kernel
    elseif node_type == PERIODIC
        @addr(uniform_continuous(0, 1), agg_addr => :scale)
        @addr(uniform_continuous(0, 1), agg_addr => :period)

    # plus combinator
    elseif node_type == PLUS
        child1 = get_child(cur, 1, max_branch)
        child2 = get_child(cur, 2, max_branch)
        @splice(subtree_proposal_recursive(child1))
        @splice(subtree_proposal_recursive(child2))

    # times combinator
    elseif node_type == TIMES
        child1 = get_child(cur, 1, max_branch)
        child2 = get_child(cur, 2, max_branch)
        @splice(subtree_proposal_recursive(child1))
        @splice(subtree_proposal_recursive(child2))

    # unknown node type
    else
        error("Unknown node type: $node_type")
    end
end

@gen function subtree_proposal(prev_trace, root::Int)
    @addr(subtree_proposal_recursive(root), :tree, noargdiff)
end

@gen function noise_proposal(prev_trace)
    @addr(gamma(1, 1), :noise)
end

function correction(prev_trace, new_trace)
    prev_size = size(get_retval(prev_trace))
    new_size = size(get_retval(new_trace))
    log(prev_size) - log(new_size)
end

function inference(xs::Vector{Float64}, ys::Vector{Float64}, num_iters::Int, callback)

    # observed data
    constraints = DynamicAssignment()
    constraints[:ys] = ys

    # generate initial trace consistent with observed data
    (trace, _) = initialize(model, (xs,), constraints)

    # do MCMC
    local covariance_fn::Node
    local noise::Float64
    for iter=1:num_iters

        covariance_fn = get_retval(trace)
        noise = get_assmt(trace)[:noise]
        callback(covariance_fn, noise)

        # randomly pick a node to expand
        root = pick_random_node(covariance_fn, 1, max_branch)

        # do MH move on the subtree
        trace = custom_mh(trace, subtree_proposal, (root,), correction)
        
        # do MH move on the top-level white noise
        trace = custom_mh(trace, noise_proposal, ())
    end
    return (covariance_fn, noise)
end

function experiment()

    # load and rescale the airline dataset
    (xs, ys) = get_airline_dataset()
    xs_train = xs[1:100]
    ys_train = ys[1:100]
    xs_test = xs[101:end]
    ys_test = ys[101:end]

    # set seed
    Random.seed!(0)

    # print MSE and predictive log likelihood on test data
    callback = (covariance_fn, noise) -> begin
        pred_ll = predictive_ll(covariance_fn, noise, xs_train, ys_train, xs_test, ys_test)
        mse = compute_mse(covariance_fn, noise, xs_train, ys_train, xs_test, ys_test)
        println("mse: $mse, predictive log likelihood: $pred_ll")
    end

    # do inference, time it
    @time (covariance_fn, noise) = inference(xs_train, ys_train, 1000, callback)

    # sample predictions
    pred_ys = predict_ys(covariance_fn, noise, xs_train, ys_train, xs_test)
end

experiment()
