#include <limits>

#include "gpu_hashmap.cuh"
#include "hash_dna.h"
#include "hash_int.h"
#include "sketch_database.h"
#include "gpu_engine.cuh"

namespace mc {

    __global__
    void insert_kernel(target_id tgt, encodedseq_t* encodedSeq, encodedambig_t* encodedAmbig) {

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
        target_id tgt,
        std::vector<encodedseq_t> encodedSeq,
        std::vector<encodedambig_t> encodedAmbig,
        size_t seqLength,
        numk_t k, size_t windowStride, sketch_size_type sketchSize)
    {
        encodedseq_t * d_encodedSeq;
        encodedambig_t * d_encodedAmbig;
        size_t encodedLength = encodedSeq.size();

        cudaMalloc(&d_encodedSeq, encodedLength*sizeof(encodedseq_t));
        cudaMalloc(&d_encodedAmbig, encodedLength*sizeof(encodedambig_t));
        CUERR

        // kmer_type * h_kmers;
        Key * d_kmers;
        ValueT * d_values;
        const size_t numWindows = (seqLength-k-1 + windowStride-1) / windowStride;
        const size_t numFeatures = numWindows * sketchSize;
        uint64_t * d_kmerCounter;
        uint64_t h_kmerCounter = 0;

        std::vector<Key> h_kmers(numFeatures);
        std::vector<ValueT> h_values(numFeatures);

        // cudaMallocHost(&h_kmers, numFeatures*sizeof(Key));
        cudaMalloc(&d_kmers, numFeatures*sizeof(Key));
        cudaMalloc(&d_values, numFeatures*sizeof(ValueT));
        CUERR
        cudaMalloc(&d_kmerCounter, sizeof(uint64_t));
        cudaMemset(d_kmerCounter, 0, sizeof(uint64_t));
        CUERR

        cudaMemcpy(d_encodedSeq, encodedSeq.data(),
                   encodedLength*sizeof(encodedseq_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_encodedAmbig, encodedAmbig.data(),
                   encodedLength*sizeof(encodedambig_t), cudaMemcpyHostToDevice);
        CUERR

        // insert_kernel<<<1,1>>>(tgt, d_encodedSeq, d_encodedAmbig);

        #define BLOCK_THREADS 64

        extract_features<BLOCK_THREADS,4><<<1,BLOCK_THREADS>>>(
            tgt,
            d_encodedSeq, d_encodedAmbig, seqLength,
            k, windowStride, sketchSize,
            d_kmers,
            d_values,
            d_kmerCounter);
        cudaDeviceSynchronize();
        CUERR

        cudaMemcpy(&h_kmerCounter, d_kmerCounter, sizeof(uint64_t), cudaMemcpyDeviceToHost);
        cudaMemcpy(h_kmers.data(), d_kmers, h_kmerCounter*sizeof(Key), cudaMemcpyDeviceToHost);
        cudaMemcpy(h_values.data(), d_values, h_kmerCounter*sizeof(ValueT), cudaMemcpyDeviceToHost);
        CUERR

        std::cout << "Target ID: " << tgt << '\n';
        //print kmers
        // for(size_t i=0; i<h_kmerCounter; ++i) {
        //     std:: cout << h_kmers[i] << ' ';
        //     if((i+1) % sketchSize == 0)
        //         std::cout << '\n';
        // }
        // std::cout << std::endl;

        // for(size_t i=0; i<h_kmerCounter; ++i) {
        //     std:: cout << '(' << h_values[i].tgt << ',' << h_values[i].win << ") " ;
        //     if((i+1) % sketchSize == 0)
        //         std::cout << '\n';
        // }
        // std::cout << std::endl;

        return h_kmers;
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
