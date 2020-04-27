/******************************************************************************
 *
 * MetaCache - Meta-Genomic Classification Tool
 *
 * Copyright (C) 2016-2019 André Müller (muellan@uni-mainz.de)
 *                       & Robin Kobus  (kobus@uni-mainz.de)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *****************************************************************************/

#ifndef MC_QUERYING_H_
#define MC_QUERYING_H_

#include <vector>
#include <iostream>

#include "sketch_database.h"
#include "sequence_io.h"
#include "cmdline_utility.h"
#include "query_options.h"
#include "cmdline_utility.h"
#include "batch_processing.h"
#include "query_batch.cuh"

#include "../dep/queue/concurrentqueue.h"


namespace mc {


/*************************************************************************//**
 *
 * @brief single query = id + header + read(pair)
 *
 *****************************************************************************/
struct sequence_query
{
    sequence_query() = default;
    sequence_query(const sequence_query&) = default;
    sequence_query(sequence_query&&) = default;
    sequence_query& operator = (const sequence_query&) = default;
    sequence_query& operator = (sequence_query&&) = default;

    explicit
    sequence_query(query_id qid, std::string headerText,
                   sequence s1, sequence s2 = sequence{}) noexcept
    :
        id{qid}, header(std::move(headerText)),
        seq1(std::move(s1)), seq2(std::move(s2))
    {}

    bool empty() const noexcept { return header.empty() || seq1.empty(); }

    query_id id = 0;
    std::string header;
    sequence seq1;
    sequence seq2;  // 2nd part of paired-end read
};



/*************************************************************************//**
 *
 * @brief process batch of results from gpu database query
 *
 * @tparam Buffer        batch buffer object
 *
 * @tparam BufferUpdate  takes database matches of one query and a buffer;
 *                       must be thread-safe (only const operations on DB!)
 *
 *****************************************************************************/
template<class Buffer, class BufferUpdate>
void process_gpu_batch_results(
    const std::vector<sequence_query>& sequenceBatch,
    bool copyAllHits,
    query_batch<location>& queryBatch,
    Buffer& batchBuffer, BufferUpdate& update)
{
    if(queryBatch.num_queries_device() > 0) {
        queryBatch.sync_result_stream();

        // std::cout << "segment offsets: ";
        // for(size_t i = 0; i < queryBatch.num_segments()+1; ++i) {
        //     std::cout << queryBatch.result_offsets_host()[i] << ' ';
        // }
        // std::cout << '\n';

        for(size_t s = 0; s < queryBatch.num_segments_device(); ++s) {
            span<location> results = copyAllHits ? queryBatch.results(s) : span<location>();

            // std::cout << s << ". targetMatches:    ";
            // for(const auto& m : results)
            //     std::cout << m.tgt << ':' << m.win << ' ';
            // std::cout << '\n';

            span<match_candidate> tophits = queryBatch.top_candidates(s);

            // std::cout << s << ". top hits: ";
            // for(const auto& t : tophits) {
            //     if(t.hits > 0) {
            //         if(t.tax)
            //             std::cout << t.tax->id() << ':' << t.hits << ' ';
            //         else
            //             std::cout << "notax:"  << t.hits << ' ';
            //     }
            // }
            // std::cout << '\n';

            update(batchBuffer, sequenceBatch[s], results, tophits);
        }
        // std::cout << '\n';

        queryBatch.clear_device();
    }
}

/*************************************************************************//**
 *
 * @brief schedule batch of sequence data for gpu database query
 *
 *****************************************************************************/
template<int I = 0>
void schedule_gpu_batch(
    const database& db,
    const classification_options& opt,
    bool copyAllHits,
    query_batch<location>& queryBatch)
{
    if(queryBatch.num_queries_host() > 0) {

        queryBatch.copy_queries_to_device_async();

        db.query_gpu_async(queryBatch, copyAllHits, opt.lowestRank);

        queryBatch.wait_for_queries_copied();

        queryBatch.clear_host();
    }
}



 /*************************************************************************//**
 *
 * @brief queries database with batches of reads from ONE sequence source (pair)
 *        produces batch buffers with one match list per sequence
 *
 * @tparam BufferSource     returns a per-batch buffer object
 *
 * @tparam BufferUpdate     takes database matches of one query and a buffer;
 *                          must be thread-safe (only const operations on DB!)
 *
 * @tparam BufferSink       recieves buffer after batch is finished
 *
 * @tparam InfoCallback     prints messages
 *
 * @tparam ProgressHandler  prints progress messages
 *
 * @tparam ErrorHandler     handles exceptions
 *
 *****************************************************************************/
template<
    class BufferSource, class BufferUpdate, class BufferSink,
    class ErrorHandler
>
query_id query_batched(
    const std::string& filename1, const std::string& filename2,
    const database& db,
    const query_options& opt,
    query_id idOffset,
    BufferSource&& getBuffer, BufferUpdate&& update, BufferSink&& finalize,
    ErrorHandler&& handleErrors)
{
    if(opt.process.queryLimit < 1) return idOffset;
    auto queryLimit = size_t(opt.process.queryLimit > 0 ? opt.process.queryLimit : std::numeric_limits<size_t>::max());

    bool copyAllHits = opt.output.showAllHits
                    || opt.output.showHitsPerTargetList
                    || opt.classify.covPercentile > 0;

    std::mutex finalizeMtx;

    // each thread may have a gpu batch for querying
    std::vector<std::unique_ptr<query_batch<location>>> gpuBatches(opt.process.numThreads);

    std::vector<std::vector<sequence_query>> swapBatches(opt.process.numThreads);
    for(auto& batch : swapBatches) {
        batch.resize(32);
    }

    // get executor that runs classification in batches
    batch_processing_options<sequence_query> execOpt;
    execOpt.concurrency(1, opt.process.numThreads - 1);
    execOpt.batch_size(opt.process.batchSize);
    execOpt.queue_size(opt.process.numThreads > 1 ? opt.process.numThreads + 4 : 0);
    execOpt.on_error(handleErrors);
    execOpt.work_item_measure([&] (const auto& query) {
        using std::begin;
        using std::end;
        using std::distance;

        const numk_t kmerSize = db.query_sketcher().kmer_size();
        const size_t windowStride = db.query_sketcher().window_stride();

        const size_t seqLength1 = distance(begin(query.seq1), end(query.seq1));
        const size_t seqLength2 = distance(begin(query.seq2), end(query.seq2));

        const window_id numWindows1 = (seqLength1-kmerSize + windowStride) / windowStride;
        const window_id numWindows2 = (seqLength2-kmerSize + windowStride) / windowStride;

        return std::max(window_id(1), numWindows1 + numWindows2);
    });

    execOpt.on_work_done([&](int id) {
        if(gpuBatches[id]) {
            auto resultsBuffer = getBuffer();

            // process last batch
            process_gpu_batch_results(swapBatches[id], copyAllHits, *(gpuBatches[id]), resultsBuffer, update);

            std::lock_guard<std::mutex> lock(finalizeMtx);
            finalize(std::move(resultsBuffer));
        }
    });

    batch_executor<sequence_query> executor {
        execOpt,
        // classifies a batch of input queries
        [&](int id, std::vector<sequence_query>& batch) {
            auto resultsBuffer = getBuffer();

            if(!gpuBatches[id])
                gpuBatches[id] = std::make_unique<query_batch<location>>(
                    opt.process.batchSize,
                    opt.process.batchSize*db.query_sketcher().window_size(),
                    db.query_sketcher().sketch_size()*db.max_locations_per_feature(),
                    opt.classify.maxNumCandidatesPerQuery);

            for(const auto& seq : batch) {
                if(!gpuBatches[id]->add_paired_read(seq.seq1, seq.seq2, db.query_sketcher(), opt.classify.insertSizeMax)) {
                    std::cerr << "query batch is too small for a single read!" << std::endl;
                }
            }
            // process results from previous batch
            process_gpu_batch_results(swapBatches[id], copyAllHits, *(gpuBatches[id]), resultsBuffer, update);
            // send new batch to gpu
            schedule_gpu_batch(db, opt.classify, copyAllHits, *(gpuBatches[id]));

            batch.swap(swapBatches[id]);

            std::lock_guard<std::mutex> lock(finalizeMtx);
            finalize(std::move(resultsBuffer));
        }};

    // read sequences from file
    try {
        sequence_pair_reader reader{filename1, filename2};
        reader.index_offset(idOffset);

        while(reader.has_next()) {
            if(queryLimit < 1) break;

            // get (ref to) next query sequence storage and fill it
            auto& query = executor.next_item();
            query.id = reader.next_header_and_data(query.header, query.seq1, query.seq2);

            --queryLimit;
        }

        idOffset = reader.index();
    }
    catch(std::exception& e) {
        handleErrors(e);
    }

    return idOffset;
}




 /*************************************************************************//**
 *
 * @brief queries database with batches of reads from multiple sequence sources
 *
 * @tparam BufferSource     returns a per-batch buffer object
 *
 * @tparam BufferUpdate     takes database matches of one query and a buffer;
 *                          must be thread-safe (only const operations on DB!)
 *
 * @tparam BufferSink       recieves buffer after batch is finished
 *
 * @tparam InfoCallback     prints messages
 *
 * @tparam ProgressHandler  prints progress messages
 *
 * @tparam ErrorHandler     handles exceptions
 *
 *****************************************************************************/
template<
    class BufferSource, class BufferUpdate, class BufferSink,
    class InfoCallback, class ProgressHandler, class ErrorHandler
>
void query_database(
    const std::vector<std::string>& infilenames,
    const database& db,
    const query_options& opt,
    BufferSource&& bufsrc, BufferUpdate&& bufupdate, BufferSink&& bufsink,
    InfoCallback&& showInfo, ProgressHandler&& showProgress,
    ErrorHandler&& errorHandler)
{
    const size_t stride = opt.process.pairing == pairing_mode::files ? 1 : 0;
    const std::string nofile;
    query_id queryIdOffset = 0;

    // input filenames passed to sequence reader depend on pairing mode:
    // none     -> infiles[i], ""
    // sequence -> infiles[i], infiles[i]
    // files    -> infiles[i], infiles[i+1]

    for(size_t i = 0; i < infilenames.size(); i += stride+1) {
        //pair up reads from two consecutive files in the list
        const auto& fname1 = infilenames[i];

        const auto& fname2 = (opt.process.pairing == pairing_mode::none)
                             ? nofile : infilenames[i+stride];

        if(opt.process.pairing == pairing_mode::files) {
            showInfo(fname1 + " + " + fname2);
        } else {
            showInfo(fname1);
        }
        showProgress(infilenames.size() > 1 ? i/float(infilenames.size()) : -1);

        queryIdOffset = query_batched(fname1, fname2, db, opt, queryIdOffset,
                                     std::forward<BufferSource>(bufsrc),
                                     std::forward<BufferUpdate>(bufupdate),
                                     std::forward<BufferSink>(bufsink),
                                     errorHandler);
    }
}



/*************************************************************************//**
 *
 * @brief queries database
 *
 * @tparam BufferSource  returns a per-batch buffer object
 *
 * @tparam BufferUpdate  takes database matches of one query and a buffer;
 *                       must be thread-safe (only const operations on DB!)
 *
 * @tparam BufferSink    recieves buffer after batch is finished
 *
 * @tparam InfoCallback  prints status messages
 *
 *****************************************************************************/
template<
    class BufferSource, class BufferUpdate, class BufferSink, class InfoCallback
>
void query_database(
    const std::vector<std::string>& infilenames,
    const database& db,
    const query_options& opt,
    BufferSource&& bufsrc, BufferUpdate&& bufupdate, BufferSink&& bufsink,
    InfoCallback&& showInfo)
{
    query_database(infilenames, db, opt,
       std::forward<BufferSource>(bufsrc),
       std::forward<BufferUpdate>(bufupdate),
       std::forward<BufferSink>(bufsink),
       std::forward<InfoCallback>(showInfo),
       [] (float p) { show_progress_indicator(std::cerr, p); },
       [] (std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; }
    );
}


} // namespace mc


#endif
