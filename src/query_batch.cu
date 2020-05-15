
#include "query_batch.cuh"
#include "sketch_database.h"
#include "gpu_result_processing.cuh"

#include "cub/device/device_scan.cuh"

#include "../dep/bb_segsort/src/bb_segsort_keys.cuh"

namespace mc {


//---------------------------------------------------------------
template<class Location>
class query_batch<Location>::segmented_sort
{
    using location_type_equivalent = uint64_t;

    static_assert(sizeof(location_type) == sizeof(location_type_equivalent), "location_type must be 64 bit");

public:
    segmented_sort(
        location_type_equivalent *d_keys, location_type_equivalent *d_keysB,
        const int *d_segs,
        int *d_binnedSegIds,
        int *d_segBinCounters_,
        cudaStream_t stream)
    :
        sorter_{d_keys, d_keysB,
            d_segs, d_binnedSegIds, d_segBinCounters_,
            stream}
    {}

    void run(int numSegs, cudaStream_t stream) const {
        sorter_.run(numSegs, stream);
    }

private:
    bb_segsort_keys<location_type_equivalent> sorter_;
};


//---------------------------------------------------------------
template<class Location>
query_batch<Location>::query_host_input::query_host_input(
    index_type maxQueries,
    size_type maxSequenceLength
) :
    numSegments_{0},
    numQueries_{0}
{
    cudaMallocHost(&queryIds_, maxQueries*sizeof(index_type));
    cudaMallocHost(&sequenceOffsets_, (maxQueries+1)*sizeof(size_type));
    sequenceOffsets_[0] = 0;
    cudaMallocHost(&sequences_, maxSequenceLength*sizeof(char));
    cudaMallocHost(&maxWindowsInRange_, maxQueries*sizeof(window_id));
    CUERR
}
//---------------------------------------------------------------
template<class Location>
query_batch<Location>::query_host_input::~query_host_input()
{
    if(queryIds_)          cudaFreeHost(queryIds_);
    if(sequenceOffsets_)   cudaFreeHost(sequenceOffsets_);
    if(sequences_)         cudaFreeHost(sequences_);
    if(maxWindowsInRange_) cudaFreeHost(maxWindowsInRange_);
    CUERR
}


//---------------------------------------------------------------
template<class Location>
query_batch<Location>::query_host_output::query_host_output(
    index_type maxQueries,
    size_type maxResultsPerQuery,
    size_type maxCandidatesPerQuery
) :
    numSegments_{0},
    numQueries_{0}
{
    cudaMallocHost(&queryResults_, maxQueries*maxResultsPerQuery*sizeof(location_type));
    cudaMallocHost(&resultOffsets_, (maxQueries+1)*sizeof(int));
    resultOffsets_[0] = 0;
    cudaMallocHost(&topCandidates_, maxQueries*maxCandidatesPerQuery*sizeof(match_candidate));
    CUERR
}
template<class Location>
query_batch<Location>::query_host_output::~query_host_output()
{
    if(queryResults_)  cudaFreeHost(queryResults_);
    if(resultOffsets_) cudaFreeHost(resultOffsets_);
    if(topCandidates_) cudaFreeHost(topCandidates_);
    CUERR
}


//---------------------------------------------------------------
template<class Location>
query_batch<Location>::query_gpu_data::query_gpu_data(
    index_type maxQueries,
    size_type maxSequenceLength,
    size_type maxResultsPerQuery,
    size_type maxCandidatesPerQuery,
    bool multiGPU,
    gpu_id gpuId
)
{
    size_t allocatedGpuMem = 0;

    cudaMalloc    (&queryIds_, maxQueries*sizeof(index_type));
    allocatedGpuMem += maxQueries*sizeof(index_type);
    if(gpuId == 0) {
        cudaMalloc    (&sequenceOffsets_, (maxQueries+1)*sizeof(size_type));
        allocatedGpuMem += (maxQueries+1)*sizeof(size_type);
        cudaMalloc    (&sequences_, maxSequenceLength*sizeof(char));
        allocatedGpuMem += maxSequenceLength*sizeof(char);
    }
    else {
        sequenceOffsets_ = nullptr;
        sequences_ = nullptr;
    }

    if(multiGPU) {
        cudaMalloc    (&sketches_, maxQueries*sizeof(feature_type));
        allocatedGpuMem += maxQueries*sizeof(feature_type);
    }
    else {
        sketches_ = nullptr;
    }
    cudaMalloc    (&queryResults_, maxQueries*maxResultsPerQuery*sizeof(location_type));
    cudaMalloc    (&queryResultsTmp_, maxQueries*maxResultsPerQuery*sizeof(location_type));
    allocatedGpuMem += 2*maxQueries*maxResultsPerQuery*sizeof(location_type);
    cudaMalloc    (&resultOffsets_, (maxQueries+1)*sizeof(int));
    allocatedGpuMem += (maxQueries+1)*sizeof(int);
    cudaMemset(resultOffsets_, 0, sizeof(int));
    cudaMalloc    (&resultCounts_, maxQueries*sizeof(int));
    allocatedGpuMem += maxQueries*sizeof(int);
    cudaMalloc    (&segBinCounters_, (SEGBIN_NUM+1)*sizeof(int));
    allocatedGpuMem += (SEGBIN_NUM+1)*sizeof(int);
    cudaMalloc    (&topCandidates_, maxQueries*maxCandidatesPerQuery*sizeof(match_candidate));
    allocatedGpuMem += maxQueries*maxCandidatesPerQuery*sizeof(match_candidate);
    cudaMalloc    (&maxWindowsInRange_, maxQueries*sizeof(window_id));
    allocatedGpuMem += maxQueries*sizeof(window_id);
    CUERR

    // std::cerr << "query batch size on gpu: " << (allocatedGpuMem >> 20) << " MB\n";

    cudaStreamCreate(&workStream_);
    cudaStreamCreate(&copyStream_);
    CUERR
    cudaEventCreate(&sketchesReadyEvent_);
    cudaEventCreate(&sketchesCopiedEvent_);
    cudaEventCreate(&offsetsReadyEvent_);
    cudaEventCreate(&offsetsCopiedEvent_);
    cudaEventCreate(&allhitsReadyEvent_);
    cudaEventCreate(&allhitsCopiedEvent_);
    cudaEventCreate(&tophitsReadyEvent_);
    cudaEventCreate(&tophitsCopiedEvent_);
    CUERR
}
//---------------------------------------------------------------
template<class Location>
query_batch<Location>::query_gpu_data::query_gpu_data(query_gpu_data&& other)
{
    queryIds_ = other.queryIds_;
    other.queryIds_ = nullptr;
    sequenceOffsets_ = other.sequenceOffsets_;
    other.sequenceOffsets_ = nullptr;
    sequences_ = other.sequences_;
    other.sequences_ = nullptr;
    sketches_ = other.sketches_;
    other.sketches_ = nullptr;
    queryResults_ = other.queryResults_;
    other.queryResults_ = nullptr;
    queryResultsTmp_ = other.queryResultsTmp_;
    other.queryResultsTmp_ = nullptr;
    resultOffsets_ = other.resultOffsets_;
    other.resultOffsets_ = nullptr;
    resultCounts_ = other.resultCounts_;
    other.resultCounts_ = nullptr;
    segBinCounters_ = other.segBinCounters_;
    other.segBinCounters_ = nullptr;
    topCandidates_ = other.topCandidates_;
    other.topCandidates_ = nullptr;
    maxWindowsInRange_ = other.maxWindowsInRange_;
    other.maxWindowsInRange_ = nullptr;

    workStream_ = other.workStream_;
    other.workStream_ = 0;
    copyStream_ = other.copyStream_;
    other.copyStream_ = 0;

    sketchesReadyEvent_ = other.sketchesReadyEvent_;
    other.sketchesReadyEvent_ = 0;
    sketchesCopiedEvent_ = other.sketchesCopiedEvent_;
    other.sketchesCopiedEvent_ = 0;
    offsetsReadyEvent_ = other.offsetsReadyEvent_;
    other.offsetsReadyEvent_ = 0;
    offsetsCopiedEvent_ = other.offsetsCopiedEvent_;
    other.offsetsCopiedEvent_ = 0;
    allhitsReadyEvent_ = other.allhitsReadyEvent_;
    other.allhitsReadyEvent_ = 0;
    allhitsCopiedEvent_ = other.allhitsCopiedEvent_;
    other.allhitsCopiedEvent_ = 0;
    tophitsReadyEvent_ = other.tophitsReadyEvent_;
    other.tophitsReadyEvent_ = 0;
    tophitsCopiedEvent_ = other.tophitsCopiedEvent_;
    other.tophitsCopiedEvent_ = 0;
}
//---------------------------------------------------------------
template<class Location>
query_batch<Location>::query_gpu_data::~query_gpu_data()
{
    if(queryIds_)          cudaFree    (queryIds_);
    if(sequenceOffsets_)   cudaFree    (sequenceOffsets_);
    if(sequences_)         cudaFree    (sequences_);
    if(sketches_)          cudaFree    (sketches_);
    if(queryResults_)      cudaFree    (queryResults_);
    if(queryResultsTmp_)   cudaFree    (queryResultsTmp_);
    if(resultOffsets_)     cudaFree    (resultOffsets_);
    if(resultCounts_)      cudaFree    (resultCounts_);
    if(segBinCounters_)    cudaFree    (segBinCounters_);
    if(topCandidates_)     cudaFree    (topCandidates_);
    if(maxWindowsInRange_) cudaFree    (maxWindowsInRange_);
    CUERR
    if(workStream_) cudaStreamDestroy(workStream_);
    if(copyStream_) cudaStreamDestroy(copyStream_);
    CUERR
    if(sketchesReadyEvent_)  cudaEventDestroy(sketchesReadyEvent_);
    if(sketchesCopiedEvent_) cudaEventDestroy(sketchesCopiedEvent_);
    if(offsetsReadyEvent_)  cudaEventDestroy(offsetsReadyEvent_);
    if(offsetsCopiedEvent_) cudaEventDestroy(offsetsCopiedEvent_);
    if(allhitsReadyEvent_)   cudaEventDestroy(allhitsReadyEvent_);
    if(allhitsCopiedEvent_)  cudaEventDestroy(allhitsCopiedEvent_);
    if(tophitsReadyEvent_)   cudaEventDestroy(tophitsReadyEvent_);
    if(tophitsCopiedEvent_)  cudaEventDestroy(tophitsCopiedEvent_);
    CUERR
}


//---------------------------------------------------------------
template<class Location>
query_batch<Location>::query_batch(
    index_type maxQueries,
    size_type maxSequenceLength,
    size_type maxResultsPerQuery,
    size_type maxCandidatesPerQuery,
    gpu_id numGPUs
) :
    maxQueries_{maxQueries},
    maxSequenceLength_{maxSequenceLength},
    maxResultsPerQuery_{maxResultsPerQuery},
    maxCandidatesPerQuery_{maxCandidatesPerQuery},
    hostInput_{maxQueries, maxSequenceLength},
    hostOutput_{maxQueries, maxResultsPerQuery, maxCandidatesPerQuery},
    gpuData_{},
    sorters_{},
    numGPUs_{numGPUs}
{
    cudaStreamCreate(&h2dCopyStream_);

    cudaEventCreate(&queriesCopiedEvent_);
    CUERR

    using location_type_equivalent = uint64_t;
    static_assert(sizeof(location_type) == sizeof(location_type_equivalent), "location_type must be 64 bit");

    for(gpu_id gpuId = 0; gpuId < numGPUs_; ++gpuId) {
        cudaSetDevice(gpuId); CUERR

        gpuData_.emplace_back(maxQueries, maxSequenceLength, maxResultsPerQuery, maxCandidatesPerQuery, numGPUs > 1, gpuId);

        sorters_.emplace_back(
            (location_type_equivalent*)(gpuData_[gpuId].queryResultsTmp_),
            (location_type_equivalent*)(gpuData_[gpuId].queryResults_),
            gpuData_[gpuId].resultOffsets_,
            gpuData_[gpuId].resultCounts_, // reuse for binning
            gpuData_[gpuId].segBinCounters_,
            gpuData_[gpuId].workStream_);
        CUERR
    }
}
//---------------------------------------------------------------
template<class Location>
query_batch<Location>::~query_batch()
{
    cudaStreamDestroy(h2dCopyStream_);
    CUERR
    cudaEventDestroy(queriesCopiedEvent_);
    CUERR
}


//---------------------------------------------------------------
template<class Location>
void query_batch<Location>::copy_queries_to_device_async()
{
    gpu_id gpuId = 0;

    hostOutput_.numQueries_ = hostInput_.numQueries_;
    hostOutput_.numSegments_ = hostInput_.numSegments_;

    cudaMemcpyAsync(gpuData_[gpuId].queryIds_, hostInput_.queryIds_,
                    hostOutput_.numQueries_*sizeof(index_type),
                    cudaMemcpyHostToDevice, h2dCopyStream_);
    cudaMemcpyAsync(gpuData_[gpuId].sequenceOffsets_, hostInput_.sequenceOffsets_,
                    (hostOutput_.numQueries_+1)*sizeof(size_type),
                    cudaMemcpyHostToDevice, h2dCopyStream_);
    cudaMemcpyAsync(gpuData_[gpuId].sequences_, hostInput_.sequences_,
                    hostInput_.sequenceOffsets_[hostOutput_.numQueries_]*sizeof(char),
                    cudaMemcpyHostToDevice, h2dCopyStream_);
    cudaMemcpyAsync(gpuData_[gpuId].maxWindowsInRange_, hostInput_.maxWindowsInRange_,
                    hostOutput_.numSegments_*sizeof(window_id),
                    cudaMemcpyHostToDevice, h2dCopyStream_);

    cudaEventRecord(queriesCopiedEvent_, h2dCopyStream_);
    cudaStreamWaitEvent(gpuData_[gpuId].workStream_, queriesCopiedEvent_, 0);

    // cudaStreamSynchronize(h2dCopyStream_);
    // CUERR
}

//---------------------------------------------------------------
template<class Location>
void query_batch<Location>::wait_for_queries_copied()
{
    cudaEventSynchronize(queriesCopiedEvent_);
    CUERR
}


//---------------------------------------------------------------
template<class Location>
void query_batch<Location>::sync_work_stream(gpu_id gpuId)
{
    cudaStreamSynchronize(gpuData_[gpuId].workStream_);
    CUERR
}

//---------------------------------------------------------------
template<class Location>
void query_batch<Location>::sync_copy_stream(gpu_id gpuId)
{
    cudaStreamSynchronize(gpuData_[gpuId].copyStream_);
    CUERR
}


//---------------------------------------------------------------
template<class Location>
void query_batch<Location>::compact_results_async(gpu_id gpuId)
{
    size_t tempStorageBytes = maxQueries_*maxResultsPerQuery_*sizeof(location_type);
    void * d_tempStorage = (void*)(gpuData_[gpuId].queryResultsTmp_);

    cudaError_t err = cub::DeviceScan::InclusiveSum(
        d_tempStorage, tempStorageBytes,
        gpuData_[gpuId].resultCounts_, gpuData_[gpuId].resultCounts_,
        hostOutput_.numQueries_,
        gpuData_[gpuId].workStream_
    );
    // cudaStreamSynchronize(gpuData_[gpuId].workStream_);
    // CUERR

    if (err != cudaSuccess) {                       \
        std::cout << "CUDA error: " << cudaGetErrorString(err) << " : "    \
        << __FILE__ << ", line " << __LINE__ << std::endl;       \
        exit(1);                                                           \
    }

    compact_kernel<<<hostOutput_.numQueries_,128,0,gpuData_[gpuId].workStream_>>>(
        hostOutput_.numQueries_,
        gpuData_[gpuId].resultCounts_,
        maxResultsPerQuery_,
        gpuData_[gpuId].queryResults_,
        gpuData_[gpuId].queryResultsTmp_,
        gpuData_[gpuId].queryIds_,
        gpuData_[gpuId].resultOffsets_);
    // cudaStreamSynchronize(gpuData_[gpuId].workStream_);
    // CUERR
}



//---------------------------------------------------------------
template<class Location>
void query_batch<Location>::compact_sort_and_copy_allhits_async(
    bool copyAllHits,
    gpu_id gpuId)
{
    compact_results_async(gpuId);
    // cudaStreamSynchronize(gpuData_[gpuId].workStream_);
    // CUERR

    if(copyAllHits) {
        cudaEventRecord(gpuData_[gpuId].offsetsReadyEvent_, gpuData_[gpuId].workStream_);
        cudaStreamWaitEvent(gpuData_[gpuId].copyStream_, gpuData_[gpuId].offsetsReadyEvent_, 0);

        cudaMemcpyAsync(hostOutput_.resultOffsets_, gpuData_[gpuId].resultOffsets_,
                        (hostOutput_.numSegments_+1)*sizeof(int),
                        cudaMemcpyDeviceToHost, gpuData_[gpuId].copyStream_);

        cudaEventRecord(gpuData_[gpuId].offsetsCopiedEvent_, gpuData_[gpuId].copyStream_);

        // cudaStreamSynchronize(gpuData_[gpuId].copyStream_);
        // CUERR
    }

    sorters_[gpuId].run(hostOutput_.numSegments_, gpuData_[gpuId].workStream_);
    // cudaStreamSynchronize(gpuData_[gpuId].workStream_);
    // CUERR

    if(copyAllHits) {
        cudaEventRecord(gpuData_[gpuId].allhitsReadyEvent_, gpuData_[gpuId].workStream_);
        cudaStreamWaitEvent(gpuData_[gpuId].copyStream_, gpuData_[gpuId].allhitsReadyEvent_, 0);

        cudaEventSynchronize(gpuData_[gpuId].offsetsCopiedEvent_);

        cudaMemcpyAsync(hostOutput_.queryResults_, gpuData_[gpuId].queryResults_,
                        hostOutput_.resultOffsets_[hostOutput_.numSegments_]*sizeof(location_type),
                        cudaMemcpyDeviceToHost, gpuData_[gpuId].copyStream_);

        // cudaStreamSynchronize(gpuData_[gpuId].copyStream_);
        // CUERR
    }
}


//---------------------------------------------------------------
template<class Location>
void query_batch<Location>::generate_and_copy_top_candidates_async(
    const ranked_lineage * lineages,
    taxon_rank lowestRank,
    gpu_id gpuId)
{
    const index_type numBlocks = hostOutput_.numSegments_;

    //TODO different max cand cases
    if(maxCandidatesPerQuery_ <= 2) {
        constexpr int maxCandidates = 2;

        generate_top_candidates<maxCandidates><<<numBlocks,32,0,gpuData_[gpuId].workStream_>>>(
            hostOutput_.numSegments_,
            gpuData_[gpuId].resultOffsets_,
            gpuData_[gpuId].queryResults_,
            gpuData_[gpuId].maxWindowsInRange_,
            lineages,
            lowestRank,
            maxCandidatesPerQuery_,
            gpuData_[gpuId].topCandidates_);

        // cudaStreamSynchronize(gpuData_[gpuId].workStream_);
        // CUERR
    }

    cudaEventRecord(gpuData_[gpuId].tophitsReadyEvent_, gpuData_[gpuId].workStream_);
    cudaStreamWaitEvent(gpuData_[gpuId].copyStream_, gpuData_[gpuId].tophitsReadyEvent_, 0);

    // copy candidates to host
    cudaMemcpyAsync(hostOutput_.topCandidates_, gpuData_[gpuId].topCandidates_,
                    hostOutput_.numSegments_*maxCandidatesPerQuery_*sizeof(match_candidate),
                    cudaMemcpyDeviceToHost, gpuData_[gpuId].copyStream_);

    cudaEventRecord(gpuData_[gpuId].tophitsCopiedEvent_, gpuData_[gpuId].copyStream_);

    // cudaStreamSynchronize(gpuData_[gpuId].copyStream_);
    // CUERR
}


//---------------------------------------------------------------
template class query_batch<location>;

} // namespace mc
