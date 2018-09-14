/******************************************************************************
 *
 * MetaCache - Meta-Genomic Classification Tool
 *
 * Copyright (C) 2016-2018 André Müller (muellan@uni-mainz.de)
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
#include <future>

#include "config.h"
#include "sequence_io.h"
#include "cmdline_utility.h"
#include "query_options.h"
#include "cmdline_utility.h"


namespace mc {


/*************************************************************************//**
 *
 * @brief
 *
 *****************************************************************************/
struct sequence_query
{
    explicit
    sequence_query(query_id qid, std::string headerText,
                   sequence s1, sequence s2 = sequence{}) noexcept
    :
        id{qid}, header(std::move(headerText)),
        seq1(std::move(s1)), seq2(std::move(s2)),
        groundTruth{nullptr}
    {}

    bool empty() const noexcept { return header.empty() || seq1.empty(); }

    query_id id;
    std::string header;
    sequence seq1;
    sequence seq2;  //2nd part of paired-end read
    const taxon* groundTruth;
};



/*************************************************************************//**
 *
 * @param a       : merge sorted ranges in this vector
 * @param offsets : positions where the ranges begin/end
 * @param b       : use this vector as a buffer
 *
 * @details offsets.front() must be 0 and offsets.back() must be a.size()
 *
 *****************************************************************************/
template<class T>
void
merge_sort(std::vector<T>& a, std::vector<size_t>& offsets, std::vector<T>& b) {
    if(offsets.size() < 3) return;
    b.resize(a.size());

    int numChunks = offsets.size()-1;
    for(int s = 1; s < numChunks; s *= 2) {
        for(int i = 0; i < numChunks; i += 2*s) {
            auto begin = offsets[i];
            auto mid = i + s <= numChunks ? offsets[i + s] : offsets[numChunks];
            auto end = i + 2*s <= numChunks ? offsets[i + 2*s] : offsets[numChunks];
            std::merge(a.begin()+begin, a.begin()+mid,
                       a.begin()+mid, a.begin()+end,
                       b.begin()+begin);
        }
        std::swap(a, b);
    }
}



/*************************************************************************//**
 *
 * @brief queries database with batches of reads from one sequence source
 *        produces one match list per sequence
 *
 * @tparam BufferSource  returns a per-batch buffer object
 *
 * @tparam BufferUpdate  takes database matches of one query and a buffer;
 *                       must be thread-safe (only const operations on DB!)
 *
 * @tparam BufferSink    recieves buffer after batch is finished
 *
 *****************************************************************************/
template<
    class BufferSource, class BufferUpdate, class BufferSink,
    class LogCallback
>
query_id query_batched(
    const std::string& filename1, const std::string& filename2,
    const database& db, const query_processing_options& opt,
    const query_id& startId,
    BufferSource&& getBuffer, BufferUpdate&& update, BufferSink&& finalize,
    LogCallback&& log)
{
    std::mutex finalizeMtx;
    std::atomic<std::int_least64_t> queryLimit{opt.queryLimit};
    std::atomic<query_id> workId{startId};

    // store id and position of most advanced thread
    std::mutex tipMtx;
    query_id qid{startId};
    sequence_pair_reader::stream_positions pos{0,0};

    std::vector<std::future<void>> threads;
    // assign work to threads
    for(int threadId = 0; threadId < opt.numThreads; ++threadId) {
        threads.emplace_back(std::async(std::launch::async, [&] {
            sequence_pair_reader reader{filename1, filename2};

            const auto readSequentially = opt.perThreadSequentialQueries;

            std::vector<sequence_pair_reader::sequence_pair> sequences;
            sequences.reserve(readSequentially);

            match_locations matches;
            match_target_locations matchesBuffer;
            match_target_locations matchesBuffer2;

            while(reader.has_next() && queryLimit > 0) {
                auto batchBuffer = getBuffer();
                bool bufferEmpty = true;

                for(std::size_t i = 0;
                    i < opt.batchSize && queryLimit.fetch_sub(readSequentially) > 0; ++i)
                {
                    query_id myQid;
                    sequence_pair_reader::stream_positions myPos;

                    // get most recent position and query id
                    {
                        std::lock_guard<std::mutex> lock(tipMtx);
                        myQid = qid;
                        myPos = pos;
                    }
                    reader.seek(myPos);
                    if(!reader.has_next()) break;
                    reader.index_offset(myQid);

                    // get work id and skip to this read
                    auto wid = workId.fetch_add(readSequentially);
                    if(myQid != wid) {
                        reader.skip(wid-myQid);
                    }
                    if(!reader.has_next()) break;
                    for(int i = 0; i < readSequentially; ++i) {
                        sequences.emplace_back(reader.next());
                    }

                    // update most recent position and query id
                    myQid = reader.index();
                    myPos = reader.tell();
                    while(myQid > qid) {// reading qid unsafe
                        if(tipMtx.try_lock()) {
                            if(myQid > qid) {// reading qid safe
                                qid = myQid;
                                pos = myPos;
                            }
                            tipMtx.unlock();
                        }
                    }

                    for(auto& seq : sequences) {
                        if(!seq.first.header.empty()) {
                            bufferEmpty = false;
                            matchesBuffer.clear();
                            std::vector<size_t> offsets{0};

                            db.accumulate_matches(seq.first.data, matchesBuffer, offsets);
                            db.accumulate_matches(seq.second.data, matchesBuffer, offsets);

                            merge_sort(matchesBuffer, offsets, matchesBuffer2);

                            matches.clear();
                            for(auto& m : matchesBuffer)
                                matches.emplace_back(db.taxon_of_target(m.tgt), m.win);

                            update(batchBuffer,
                                   sequence_query{seq.first.index,
                                                  std::move(seq.first.header),
                                                  std::move(seq.first.data),
                                                  std::move(seq.second.data)},
                                   matches );
                        }
                    }
                    sequences.clear();
                }
                if(!bufferEmpty) {
                    std::lock_guard<std::mutex> lock(finalizeMtx);
                    finalize(std::move(batchBuffer));
                }
            }
        })); //emplace
    }

    // wait for all threads to finish and catch exceptions
    for(unsigned int threadId = 0; threadId < threads.size(); ++threadId) {
        if(threads[threadId].valid()) {
            try {
                threads[threadId].get();
            }
            catch(file_access_error& e) {
                if(threadId == 0) {
                    log(std::string("FAIL: ") + e.what());
                }
            }
            catch(std::exception& e) {
                log(std::string("FAIL: ") + e.what());
            }
        }
    }

    return qid;
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
 *****************************************************************************/
template<
    class BufferSource, class BufferUpdate, class BufferSink,
    class InfoCallback, class ProgressHandler, class LogHandler
>
void query_database(
    const std::vector<std::string>& infilenames,
    const database& db,
    const query_processing_options& opt,
    BufferSource&& bufsrc, BufferUpdate&& bufupdate, BufferSink&& bufsink,
    InfoCallback&& showInfo, ProgressHandler&& showProgress, LogHandler&& log)
{
    const size_t stride = opt.pairing == pairing_mode::files ? 1 : 0;
    const std::string nofile;
    query_id readIdOffset = 0;

    for(size_t i = 0; i < infilenames.size(); i += stride+1) {
        //pair up reads from two consecutive files in the list
        const auto& fname1 = infilenames[i];

        const auto& fname2 = (opt.pairing == pairing_mode::none)
                             ? nofile : infilenames[i+stride];

        if(opt.pairing == pairing_mode::files) {
            showInfo(fname1 + " + " + fname2);
        } else {
            showInfo(fname1);
        }
        showProgress(infilenames.size() > 1 ? i/float(infilenames.size()) : -1);

        readIdOffset = query_batched(fname1, fname2, db, opt, readIdOffset,
                                     std::forward<BufferSource>(bufsrc),
                                     std::forward<BufferUpdate>(bufupdate),
                                     std::forward<BufferSink>(bufsink),
                                     std::forward<LogHandler>(log));
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
 *****************************************************************************/
template<
    class BufferSource, class BufferUpdate, class BufferSink, class InfoCallback
>
void query_database(
    const std::vector<std::string>& infilenames,
    const database& db,
    const query_processing_options& opt,
    BufferSource&& bufsrc, BufferUpdate&& bufupdate, BufferSink&& bufsink,
    InfoCallback&& showInfo)
{
    query_database(infilenames, db, opt,
                   std::forward<BufferSource>(bufsrc),
                   std::forward<BufferUpdate>(bufupdate),
                   std::forward<BufferSink>(bufsink),
                   std::forward<InfoCallback>(showInfo),
                   [] (float p) { show_progress_indicator(std::cerr, p); },
                   [] (const std::string& s) {std::cerr << s << '\n'; }
                   );
}


} // namespace mc


#endif
