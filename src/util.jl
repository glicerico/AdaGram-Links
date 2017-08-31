function read_from_file(vocab_path::AbstractString, min_freq::Int64=0, stopwords::Set{AbstractString}=Set{AbstractString}();
		regex::Regex=r"")
	fin = open(vocab_path)
	freqs = Array(Int64, 0)
	id2word = Array(AbstractString, 0)
	while !eof(fin)
		try
			word, freq = split(readline(fin))
			freq_num = parse(Int64, freq)
			if freq_num < min_freq || word in stopwords || !ismatch(regex, word) continue end
			push!(id2word, word)
			push!(freqs, freq_num)
		catch e
		end
	end
	close(fin)

	return freqs, id2word
end

function read_from_file(vocab_path::AbstractString, M::Int, T::Int, min_freq::Int=5,
	removeTopK::Int=70, stopwords::Set{AbstractString}=Set{AbstractString}();
	regex::Regex=r"")
	freqs, id2word = read_from_file(vocab_path, min_freq, stopwords; regex=regex)

	S = sortperm(freqs, rev=true)
	freqs = freqs[S[removeTopK+1:end]]
	id2word = id2word[S[removeTopK+1:end]]

	return VectorModel(freqs, M, T), Dictionary(id2word)
end

function build_from_file(text_path::AbstractString, M::Int, T::Int, min_freq::Int64=5)
	f = open(text_path)
	freqs, id2word = count_words(f)
	close(f)

	return VectorModel(freqs, M, T), Dictionary(id2word)
end

function dict_from_file(vocab_path::AbstractString)
	freqs, id2word = read_from_file(vocab_path)

	return Dictionary(id2word)
end

function read_word2vec(path::AbstractString)
	fin = open(path)

	line = readline(fin)
	line = split(line)

	V = parse(Int64, line[1])
	M = parse(Int64, line[2])

	In = zeros(Float32, M, V)
	id2word = Array(AbstractString, 0)

	for v in 1:V
		word = readuntil(fin, ' ')[1:end-1]
		push!(id2word, word)

		In[:, v] = read(fin, Float32, (M))
		readuntil(fin, '\n')
	end

	close(fin)

	return In, Dictionary(id2word)
end

function write_word2vec(path::AbstractString, vm::VectorModel, dict::Dictionary)
	fout = open(path, "w")
	write(fout, "$(V(vm)) $(M(vm))\n")
	for v in 1:V(vm)
		write(fout, "$(dict.id2word[v]) ")
		for i in 1:M(vm)
			write(fout, vm.In[i, 1, v])
		end
		write(fout, "\n")
	end
	close(fout)
end

function finalize!(vm::VectorModel)
	vm.frequencies = sdata(vm.frequencies)
	vm.In = sdata(vm.In)
	vm.Out = sdata(vm.Out)
	vm.counts = sdata(vm.counts)
	vm.code = sdata(vm.code)
	vm.path = sdata(vm.path)
end

function save_model(path::AbstractString, vm::VectorModel, dict::Dictionary, min_prob=1e-5)
	file = open(path, "w")
	println(file, V(vm), " ", M(vm), " ", T(vm))
	println(file, vm.alpha, " ", vm.d)
	println(file, size(vm.code, 1))

	write(file, vm.frequencies)
	write(file, vm.code)
	write(file, vm.path)
	write(file, vm.counts)
	write(file, vm.Out)

	z = zeros(T(vm))

	for v in 1:V(vm)
		nsenses = expected_pi!(z, vm, v, min_prob)
		println(file, dict.id2word[v])
		println(file, nsenses)
		for k in 1:T(vm)
			if z[k] < min_prob continue end
			println(file, k)
			write(file, view(vm.In, :, k, v))
			println(file)
		end
	end

	close(file)
end

function load_model(path::AbstractString)
	file = open(path)

	_V, _M, _T = map(x -> parse(Int, x), split(readline(file)))
	alpha, d = map(x -> parse(Float64, x) , split(readline(file)))
	max_length = parse(Int, readline(file))

	vm = VectorModel(max_length, _V, _M, _T, alpha, d)
	read!(file, sdata(vm.frequencies))
	read!(file, sdata(vm.code))
	read!(file, sdata(vm.path))
	read!(file, sdata(vm.counts))
	read!(file, sdata(vm.Out))

	buffer = zeros(Float32, M(vm))

	id2word = Array(AbstractString, 0)
	for v in 1:V(vm)
		word = strip(readline(file))
		nsenses = parse(Int, readline(file))
		push!(id2word, word)

		for r in 1:nsenses
			k = parse(Int, readline(file))
			read!(file, buffer)
			vm.In[:, k, v] = buffer
			readline(file)
		end
	end

	close(file)

	return vm, Dictionary(id2word)
end

function preprocess(vm::VectorModel, doc::Array{Int32}; min_freq::Int64=5,
	subsampling_treshold::Float64 = 1e-5)
	data = Array(Int32, 0)
	total_freq = sum(vm.frequencies)

	for i in 1:length(doc)
		assert(1 <= doc[i] <= length(vm.frequencies))
		if vm.frequencies[doc[i]] < min_freq
			continue
		end

		if rand() < 1. - sqrt(subsampling_treshold / (vm.frequencies[doc[i]] / total_freq))
			continue
		end

		push!(data, doc[i])
	end

	return data
end

function vec(vm::VectorModel, v::Integer, s::Integer)
	x = vm.In[:, s, v]
	return x / norm(x)
end

function vec(vm::VectorModel, dict::Dictionary, w::AbstractString, s::Integer)
	return vec(vm, dict.word2id[w], s)
end

function nearest_neighbors(vm::VectorModel, dict::Dictionary, word::DenseArray{Tsf},
		K::Integer=10; exclude::Array{Tuple{Int32, Int64}}=Array(Tuple{Int32, Int64}, 0),
		min_count::Float64=1.)
	sim = zeros(Tsf, (T(vm), V(vm)))

	for v in 1:V(vm)
		for s in 1:T(vm)
			if vm.counts[s, v] < min_count
				sim[s, v] = -Inf
				continue
			end
			in_vs = view(vm.In, :, s, v)
			sim[s, v] = dot(in_vs, word) / norm(in_vs)
		end
	end
	for (v, s) in exclude
		sim[s, v] = -Inf
	end
	top = Array(Tuple{Int, Int}, K)
	topSim = zeros(Tsf, K)

	function split_index(sim, i)
		i -= 1
		v = i % size(sim, 1) + 1
		s = Int(floor(i / size(sim, 1))) + 1
		return v, s
	end
	for k in 1:K
		curr_max = split_index(sim, indmax(sim))
		topSim[k] = sim[curr_max[1], curr_max[2]]
		sim[curr_max[1], curr_max[2]] = -Inf

		top[k] = curr_max
	end
	return Tuple{AbstractString, Int, Tsf}[(dict.id2word[r[2]], r[1], simr)
		for (r, simr) in zip(top, topSim)]
end

function nearest_neighbors(vm::VectorModel, dict::Dictionary,
		w::AbstractString, s::Int, K::Integer=10)
	v = dict.word2id[w]
	return nearest_neighbors(vm, dict, vec(vm, v, s), K; exclude=[(v, s)])
end

cos_dist(x, y) = 1. - dot(x, y) / norm(x, 2) / norm(y, 2)

function disambiguate{Tw <: Integer}(vm::VectorModel, x::Tw,
		context::AbstractArray{Tw, 1}, use_prior::Bool=true,
		min_prob::Float64=1e-3)
	z = zeros(T(vm))

	if use_prior
		expected_pi!(z, vm, x)
		for k in 1:T(vm)
			if z[k] < min_prob
				z[k] = 0.
			end
			z[k] = log(z[k])
		end
	end
	for y in context
		var_update_z!(vm, x, y, z)
	end

	exp_normalize!(z)
	
	return z
end

function disambiguate{Ts <: AbstractString}(vm::VectorModel, dict::Dictionary, x::AbstractString, context::AbstractArray{Ts, 1}, use_prior::Bool=true, min_prob::Float64=1e-3)
	return disambiguate(vm, dict.word2id[x], Int32[dict.word2id[y] for y in context], use_prior, min_prob)
end


# Performs clustering using K-means algorithm adapted from word2vec
# clustering routine, but handling the representation vector for each
# different significant meaning of a word. A word can (and probably should)
# end up in different clusters, according to its different meanings.
function clustering(vm::VectorModel, dict::Dictionary, outputFile::AbstractString,
        K::Integer=100; min_prob=1e-3)
	wordVectors = Float32[]
	words = AbstractString[]

	# Builds arrays of words and their vectors
	for w in 1:V(vm)
		probVec = expected_pi(vm, w)
		for iMeaning in 1:T(vm)
			# ignores senses that do not reach min probability
			if probVec[iMeaning] > min_prob
				push!(words, dict.id2word[w])
				currentVector = vm.In[:, iMeaning, w]
				for currentValue in currentVector 
					push!(wordVectors, currentValue)
				end
			end
		end
	end

	# Calls the actual classifier, from a c-function
	ccall((:kmeans, "superlib"), Void,
	    (Ptr{Ptr{Cchar}}, Ptr{Float32},
	    	Int, Int, Int, Ptr{Cchar}), 
	    words, wordVectors, K, size(words, 1), M(vm), outputFile)

	println("Finished clustering")
end

# clustering routine using k-means, modified in the spirit of Clark2000 to account
# for words that don't clearly fit in a cluster and merging clusters
function clarkClustering(vm::VectorModel, dict::Dictionary, outputFile::AbstractString;
	    K::Integer=100, min_prob=1e-2, termination_fraction=0.8, merging_threshold=0.9,
        fraction_increase=0.05)
    wordVectors = []
    senses = Int64[]
    wordFrequencies = Int64[]
    clusters = []

    function calculateCenter(currentCluster::Int64)
        currentCenter = zeros(Float32, M(vm))
        for iMember in 1:length(clusters[currentCluster])
            currentCenter += wordVectors[clusters[currentCluster][iMember]]
        end
        #currentCenter /= length(clusters[iCluster]) # averages the centers of every member of the class
        currentCenter /= norm(currentCenter) # normalizes the center vector
        return currentCenter
    end

    # Builds arrays of senses and their vectors
    for w in 1:V(vm)
        probVec = expected_pi(vm, w)
        for iMeaning in 1:T(vm)
            # ignores senses that do not reach min probability
            if probVec[iMeaning] > min_prob
                push!(senses, w)
                push!(wordFrequencies, round(vm.counts[iMeaning, w]))
                currentVec = vm.In[:, iMeaning, w]
                push!(wordVectors, currentVec/norm(currentVec)) # normalizes wordVectors
            end
        end
    end


    numSenses = length(senses) # total num of unique senses to cluster
    orderFreq = sortperm(wordFrequencies, rev = true) # ordered indexes of most freq. senses

    # Initialize clusters with the next most frequent sense available
    # and cluster centers with zeros
    clusterCenters = []
    for iCluster in 1:K
        push!(clusters, [orderFreq[iCluster]])
        push!(clusterCenters, zeros(Float32, M(vm))) 
    end

    # initialize closestCluster, closestClusterDistance
    closestCluster = zeros(Int32, numSenses)
    closestClusterDistance = zeros(Float32, numSenses)

    numClusteredSenses = K 
    orderDistance = Int64[]
    # keeps clustering senses until termination_fraction of them are clustered
    while numClusteredSenses <= numSenses * termination_fraction
        # calculate cluster centers
        for iCluster in 1:K
            clusterCenters[iCluster] = calculateCenter(iCluster)
        end

        mergeFlag = false
        # If two clusters are close enough, merge and flag to return to loop start
        for iCluster in 1:K
            for iCluster2 in iCluster + 1:K
                separation = dot(clusterCenters[iCluster], clusterCenters[iCluster2])
                if separation > merging_threshold
                    append!(clusters[iCluster], clusters[iCluster2])
                    # Resets merged cluster to highest freq. unclustered sense
                    numClusteredSenses += 1
                    clusters[iCluster2] = [orderFreq[numClusteredSenses]]
                    println("Merged 2 clusters, started a new one")
                    mergeFlag = true
                    break
                end
            end
            if mergeFlag break end
        end
        if mergeFlag continue end

        # calculate each sense's projection to cluster centers, only keep the closest one
        for iWord in 1:numSenses
            projection = -Inf
            clusterId = 0
            for iCluster in 1:K
                dotProd = dot(wordVectors[iWord], clusterCenters[iCluster]) 
                if dotProd > projection
                    projection = dotProd
                    clusterId = iCluster
                end
            end
            closestCluster[iWord] = clusterId
            closestClusterDistance[iWord] = projection
        end

        # get sense order relative to distance to their nearest cluster
        orderDistance = sortperm(closestClusterDistance, rev = true)
        numClusteredSenses += round(Int32, fraction_increase * numSenses)
        # reset clusters to allow membership change
        clusters = []
        for iCluster in 1:K
            push!(clusters, [])
        end
        # assign the best senses as members of their closest cluster
        for iBest in 1:numClusteredSenses
            push!(clusters[closestCluster[orderDistance[iBest]]], orderDistance[iBest])
        end

        @printf "Percentge of word senses clustered: %0.3f \n" numClusteredSenses/numSenses
    end

    # the less frequent senses fall into a cluster in position K+1 (unclustered senses)
    push!(clusters, orderDistance[numClusteredSenses + 1:end])

    # write to specified output file
    fo = open(outputFile, "w")
    for iCluster in 1:length(clusters)
        for iMember in 1:length(clusters[iCluster])
            @printf(fo, "%s\t%d\n", dict.id2word[senses[clusters[iCluster][iMember]]], iCluster)
        end
    end
    close(fo)
end

export nearest_neighbors
export disambiguate
export pi, write_extended
export cos_dist, preprocess, read_word2vec, write_word2vec
export load_model
export clustering, clarkClustering