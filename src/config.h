/*****************************************************************************
 *
 * MetaCache - Meta-Genomic Classification Tool
 *
 * version 1.0
 *
 * Copyright (C) 2016 André Müller (muellan@uni-mainz.de)
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

/*****************************************************************************
 *
 * @file contains important type aliases
 *
 *****************************************************************************/

#ifndef MC_CONFIG_H_
#define MC_CONFIG_H_


#include "sketch_database.h"
#include "dna_hasher.h"


namespace mc {

using sequence = std::string;


#ifdef MC_MF_MINHASH
    //different hash function for each feature in sketch
    using sketcher = multi_function_min_hasher;
#else
    #ifdef MC_64BIT_KMERS
        //for 33 <= k <= 64
        using sketcher = single_function_min_hasher_64;
    #else
        //default, for 0 <= k <= 32
        using sketcher = single_function_min_hasher;
    #endif
#endif


using database   = sketch_database<sequence,sketcher>;
using taxon_rank = database::taxon_rank;
using genome_id  = database::genome_id;


#ifdef MC_VOTE8
    using top_matches_in_contiguous_window_range
            = matches_in_contiguous_window_range_top<8>;  //will use majority voting scheme
#else
    using top_matches_in_contiguous_window_range
            = matches_in_contiguous_window_range_top<2>;
#endif

} // namespace mc


#endif
