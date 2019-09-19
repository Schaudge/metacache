#include <limits>

#include "gpu_hashmap.cuh"
#include "hash_dna.h"
#include "hash_int.h"
#include "sketch_database.h"
#include "gpu_engine.cuh"

namespace mc {

//---------------------------------------------------------------
template<>
sequence_batch<policy::Host>::sequence_batch(size_t maxTargets, size_t maxEncodeLength) :
    maxTargets_{maxTargets}, maxEncodeLength_{maxEncodeLength}, numTargets_{0}
{
    if(maxTargets_) {
        cudaMallocHost(&targetIds_, maxTargets_*sizeof(target_id));
        cudaMallocHost(&windowOffsets_, maxTargets_*sizeof(window_id));
        cudaMallocHost(&encodeOffsets_, (maxTargets_+1)*sizeof(encodinglen_t));
        encodeOffsets_[0] = 0;
    }
    if(maxEncodeLength_) {
        cudaMallocHost(&encodedSeq_, maxEncodeLength_*sizeof(encodedseq_t));
        cudaMallocHost(&encodedAmbig_, maxEncodeLength_*sizeof(encodedambig_t));
    }
    CUERR
}
//---------------------------------------------------------------
template<>
sequence_batch<policy::Host>::~sequence_batch() {
    if(maxTargets_) {
        cudaFreeHost(targetIds_);
        cudaFreeHost(windowOffsets_);
        cudaFreeHost(encodeOffsets_);
    }
    if(maxEncodeLength_) {
        cudaFreeHost(encodedSeq_);
        cudaFreeHost(encodedAmbig_);
    }
    CUERR
}

//---------------------------------------------------------------
template<>
sequence_batch<policy::Device>::sequence_batch(size_t maxTargets, size_t maxEncodeLength) :
    maxTargets_{maxTargets}, maxEncodeLength_{maxEncodeLength}, numTargets_{0}
{
    if(maxTargets_) {
        cudaMalloc(&targetIds_, maxTargets_*sizeof(target_id));
        cudaMalloc(&windowOffsets_, maxTargets_*sizeof(window_id));
        cudaMalloc(&encodeOffsets_, (maxTargets_+1)*sizeof(encodinglen_t));
    }
    if(maxEncodeLength_) {
        cudaMalloc(&encodedSeq_, maxEncodeLength_*sizeof(encodedseq_t));
        cudaMalloc(&encodedAmbig_, maxEncodeLength_*sizeof(encodedambig_t));
    }
    CUERR
}
//---------------------------------------------------------------
template<>
sequence_batch<policy::Device>::~sequence_batch() {
    if(maxTargets_) {
        cudaFree(targetIds_);
        cudaFree(windowOffsets_);
        cudaFree(encodeOffsets_);
    }
    if(maxEncodeLength_) {
        cudaFree(encodedSeq_);
        cudaFree(encodedAmbig_);
    }
    CUERR
}



//---------------------------------------------------------------
template<
    class Key,
    class ValueT,
    class Hash,
    class KeyEqual,
    class BucketSizeT
>
gpu_hashmap<Key,ValueT,Hash,KeyEqual,BucketSizeT>::feature_batch::feature_batch(feature_batch::counter_type maxFeatures) :
    maxFeatures_{maxFeatures}
{
    if(maxFeatures_) {
        cudaMalloc(&features_, maxFeatures_*sizeof(Key));
        cudaMalloc(&values_, maxFeatures_*sizeof(ValueT));
        cudaMalloc(&featureCounter_, sizeof(feature_batch::counter_type));
    }
    CUERR
}
//---------------------------------------------------------------
template<
    class Key,
    class ValueT,
    class Hash,
    class KeyEqual,
    class BucketSizeT
>
gpu_hashmap<Key,ValueT,Hash,KeyEqual,BucketSizeT>::feature_batch::~feature_batch() {
    if(maxFeatures_) {
        cudaFree(features_);
        cudaFree(values_);
        cudaFree(featureCounter_);
    }
    CUERR
}


//-----------------------------------------------------
template<
    class Key,
    class ValueT,
    class Hash,
    class KeyEqual,
    class BucketSizeT
>
void gpu_hashmap<Key,ValueT,Hash,KeyEqual,BucketSizeT>::init()
{
    cudaSetDevice(0);

    //FIXME unsafe
    //possible fix: limit number of windows in sequence batch
    //shortest possible window size to create full sketch can be encoded in 2 blocks
    // const size_t winLen = 2;
    //average should be bigger than this
    const size_t winLen = 5;

    const size_t maxWindows = MAX_ENCODE_LENGTH_PER_BATCH / winLen;
    const size_t maxFeatures = maxWindows * sketchSize_;

    std::cout << "max features: " << maxFeatures << '\n';

    seqBatches_.emplace_back(MAX_TARGETS_PER_BATCH, MAX_ENCODE_LENGTH_PER_BATCH);

    featureBatches_.emplace_back(maxFeatures);
}


//-----------------------------------------------------
template<
    class Key,
    class ValueT,
    class Hash,
    class KeyEqual,
    class BucketSizeT
>
std::vector<Key> gpu_hashmap<Key,ValueT,Hash,KeyEqual,BucketSizeT>::insert(
    const sequence_batch<policy::Host>& seqBatchHost
) {
    using counter_type = typename feature_batch::counter_type;

    cudaStream_t stream = 0;

    seqBatches_[0].num_targets(seqBatchHost.num_targets());

    //copy batch to gpu
    cudaMemcpyAsync(seqBatches_[0].target_ids(), seqBatchHost.target_ids(),
                    seqBatchHost.num_targets()*sizeof(target_id),
                    cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(seqBatches_[0].window_offsets(), seqBatchHost.window_offsets(),
                    seqBatchHost.num_targets()*sizeof(window_id),
                    cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(seqBatches_[0].encode_offsets(), seqBatchHost.encode_offsets(),
                    (seqBatchHost.num_targets()+1)*sizeof(encodinglen_t),
                    cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(seqBatches_[0].encoded_seq(), seqBatchHost.encoded_seq(),
                    seqBatchHost.encode_offsets()[seqBatchHost.num_targets()]*sizeof(encodedseq_t),
                    cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(seqBatches_[0].encoded_ambig(), seqBatchHost.encoded_ambig(),
                    seqBatchHost.encode_offsets()[seqBatchHost.num_targets()]*sizeof(encodedambig_t),
                    cudaMemcpyHostToDevice, stream);

    //initialize counter
    cudaMemsetAsync(featureBatches_[0].feature_counter(), 0, sizeof(counter_type), stream);
    // cudaStreamSynchronize(stream);
    // CUERR

    // max 32*4 features => max window size is 128
    #define BLOCK_THREADS 32
    #define ITEMS_PER_THREAD 4

    //TODO increase grid in x and y dim
    constexpr dim3 numBlocks{1,1};
    extract_features<BLOCK_THREADS,ITEMS_PER_THREAD><<<numBlocks,BLOCK_THREADS,0,stream>>>(
        seqBatches_[0].num_targets(),
        seqBatches_[0].target_ids(),
        seqBatches_[0].window_offsets(),
        seqBatches_[0].encode_offsets(),
        seqBatches_[0].encoded_seq(),
        seqBatches_[0].encoded_ambig(),
        kmerLength_, sketchSize_, windowSize_, windowStride_,
        featureBatches_[0].features(),
        featureBatches_[0].values(),
        featureBatches_[0].feature_counter());
    //TODO remove later ------------------------------------------------------------
    //neccessary sync to get feature counter
    cudaStreamSynchronize(stream);
    CUERR

    counter_type h_featureCounter = 0;
    cudaMemcpyAsync(&h_featureCounter, featureBatches_[0].feature_counter(),
                sizeof(counter_type), cudaMemcpyDeviceToHost, stream);
    //neccessary sync to get feature counter
    cudaStreamSynchronize(stream);
    std::cout << "Counter: " << h_featureCounter << std::endl;

    // kmer_type * h_features;
    // cudaMallocHost(&h_features, numFeatures*sizeof(Key));
    std::vector<Key> h_features(h_featureCounter);
    std::vector<ValueT> h_values(h_featureCounter);
    cudaMemcpyAsync(h_features.data(), featureBatches_[0].features(),
                h_featureCounter*sizeof(Key), cudaMemcpyDeviceToHost, stream);
    cudaMemcpyAsync(h_values.data(), featureBatches_[0].values(),
                h_featureCounter*sizeof(ValueT), cudaMemcpyDeviceToHost, stream);
    cudaStreamSynchronize(stream);
    CUERR

    //print features
    // for(size_t i=0; i<h_featureCounter; ++i) {
    //     std:: cout << h_features[i] << ' ';
    //     if((i+1) % sketchSize_ == 0)
    //         std::cout << '\n';
    // }
    // std::cout << std::endl;

    // for(size_t i=0; i<h_featureCounter; ++i) {
    //     std:: cout << '(' << h_values[i].tgt << ',' << h_values[i].win << ") " ;
    //     if((i+1) % sketchSize_ == 0)
    //         std::cout << '\n';
    // }
    // std::cout << std::endl;

    //TODO remove later ------------------------------------------------------------

    return h_features;
}





//-----------------------------------------------------
template class gpu_hashmap<
        kmer_type,
        location,
        // uint64_t,
        same_size_hash<kmer_type>,
        std::equal_to<kmer_type>,
        unsigned char
        >;

} // namespace mc
