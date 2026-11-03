/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2022. All rights reserved.
 * Description: LZ4K compression algorithm with delta compression
 */

#include <linux/module.h>

#include "lz4kd_private.h" /* types, etc */

static const uint8_t *get_size(
	uint_fast32_t *size,
	const uint8_t *in_at,
	const uint8_t *const in_end)
{
	uint_fast32_t u;
	do {
		if (unlikely(in_at >= in_end))
			return NULL;
		*size += (u = *(const uint8_t*)in_at);
		++in_at;
	} while (BYTE_MAX == u);
	return in_at;
}

static int end_of_block(
	const uint_fast32_t nr_bytes_max,
	const uint_fast32_t r_bytes_max,
	const uint8_t *const in_at,
	const uint8_t *const in_end,
	const uint8_t *const out,
	const uint8_t *const out_at)
{
	if (!nr_bytes_max)
		return LZ4K_STATUS_FAILED; /* should be the last one in block */
	if (r_bytes_max != REPEAT_MIN)
		return LZ4K_STATUS_FAILED; /* should be the last one in block */
	if (in_at != in_end)
		return LZ4K_STATUS_FAILED; /* should be the last one in block */
	return (int)(out_at - out);
}

enum {
	NR_COPY_MIN = 16,
	R_COPY_MIN = 16,
	R_COPY_SAFE = R_COPY_MIN - 1,
	R_COPY_SAFE_2X = (R_COPY_MIN << 1) - 1
};

static bool out_non_repeat(
        const uint8_t **in_at,
        uint8_t **out_at,
        uint_fast32_t nr_bytes_max,
        const uint8_t *const in_end,
        const uint8_t *const out_end)
{
        size_t in_remaining;
        size_t out_remaining;
        const uint8_t *in_copy_end;
        uint8_t *out_copy_end;

        /*
         * Validate current positions before calculating end pointers.
         */
        if (unlikely(*in_at > in_end || *out_at > out_end))
                return false;

        in_remaining = (size_t)(in_end - *in_at);
        out_remaining = (size_t)(out_end - *out_at);

        if (unlikely(nr_bytes_max > in_remaining ||
                     nr_bytes_max > out_remaining))
                return false;

        in_copy_end = *in_at + nr_bytes_max;
        out_copy_end = *out_at + nr_bytes_max;

        if (likely(nr_bytes_max <= NR_COPY_MIN)) {
                if (likely(in_remaining >= NR_COPY_MIN &&
                           out_remaining >= NR_COPY_MIN)) {
                        m_copy(*out_at, *in_at, NR_COPY_MIN);
                } else {
                        m_copy(*out_at, *in_at, nr_bytes_max);
                }
        } else {
                if (likely(in_remaining - nr_bytes_max >= NR_COPY_MIN &&
                           out_remaining - nr_bytes_max >= NR_COPY_MIN)) {
                        m_copy(*out_at, *in_at, NR_COPY_MIN);
                        copy_x_while_lt(*out_at + NR_COPY_MIN,
                                        *in_at + NR_COPY_MIN,
                                        out_copy_end, NR_COPY_MIN);
                } else {
                        m_copy(*out_at, *in_at, nr_bytes_max);
                }
        }

        *in_at = in_copy_end;
        *out_at = out_copy_end;
        return true;
}

static void out_repeat_overlap(
        uint_fast32_t offset,
        uint8_t *out_at,
        const uint8_t *const out_copy_end)
{
        /*
         * Forward propagation is required for overlapping LZ matches.
         * Do not use memcpy here: source and destination may overlap.
         */
        while (out_at < out_copy_end) {
                *out_at = *(out_at - offset);
                ++out_at;
        }
}

static bool out_repeat_slow(
        uint_fast32_t r_bytes_max,
        uint_fast32_t offset,
        uint8_t *out_at,
        const uint8_t *out_from,
        const uint8_t *const out_copy_end,
        const uint8_t *const out_end)
{
        if (unlikely(out_copy_end > out_end))
                return false;

        if (offset > 1 &&
            (size_t)(out_end - out_copy_end) >= R_COPY_SAFE_2X) {
                out_repeat_overlap(offset, out_at, out_copy_end);
        } else {
                if (offset == 1) {
                        m_set(out_at, *out_from, r_bytes_max);
                } else {
                        do
                                *out_at++ = *out_from++;
                        while (out_at < out_copy_end);
                }
        }

        return true;
}

static int decode(
        const uint8_t *in_at,
        uint8_t *const out,
        const uint8_t *const in_end,
        const uint8_t *const out_end,
        const uint_fast32_t nr_log2,
        const uint_fast32_t off_log2)
{
        const uint_fast32_t r_log2 = TAG_BITS_MAX - (off_log2 + nr_log2);
        uint8_t *out_at = out;

        while (likely(in_at <= in_end &&
                      (size_t)(in_end - in_at) >= TAG_BYTES_MAX)) {
                const uint_fast32_t utag = read4_at(in_at - 1) >> BYTE_BITS;
                const uint_fast32_t offset = utag & mask(off_log2);
                uint_fast32_t nr_bytes_max = utag >> (off_log2 + r_log2),
                              r_bytes_max = ((utag >> off_log2) & mask(r_log2)) +
                                            REPEAT_MIN;

                const uint8_t *out_from;
                uint8_t *out_copy_end;

                in_at += TAG_BYTES_MAX;

                if (unlikely(nr_bytes_max == mask(nr_log2))) {
                        in_at = get_size(&nr_bytes_max, in_at, in_end);
                        if (unlikely(in_at == NULL))
                                return LZ4K_STATUS_READ_ERROR;
                }

                if (!out_non_repeat(&in_at, &out_at, nr_bytes_max,
                                    in_end, out_end))
                        return LZ4K_STATUS_FAILED;

                if (unlikely(r_bytes_max == mask(r_log2) + REPEAT_MIN)) {
                        in_at = get_size(&r_bytes_max, in_at, in_end);
                        if (unlikely(in_at == NULL))
                                return LZ4K_STATUS_READ_ERROR;
                }

                /*
                 * Offset zero marks the end of the block.
                 * Handle it before calculating out_at - offset.
                 */
                if (unlikely(offset == 0)) {
                        return end_of_block(nr_bytes_max, r_bytes_max,
                                            in_at, in_end, out, out_at);
                }

                /*
                 * Validate the back-reference against already decoded data.
                 */
                if (unlikely(out_at < out ||
                             offset > (size_t)(out_at - out)))
                        return LZ4K_STATUS_FAILED;

                /*
                 * Validate output capacity before forming out_copy_end.
                 */
                if (unlikely(out_at > out_end ||
                             r_bytes_max > (size_t)(out_end - out_at)))
                        return LZ4K_STATUS_FAILED;

                out_from = out_at - offset;
                out_copy_end = out_at + r_bytes_max;

                if (likely(offset >= R_COPY_MIN &&
                           (size_t)(out_end - out_copy_end) >=
                           R_COPY_SAFE_2X)) {
                        copy_2x_as_x2_while_lt(out_at, out_from,
                                               out_copy_end, R_COPY_MIN);
                } else if (likely(offset >= (R_COPY_MIN >> 1) &&
                                  (size_t)(out_end - out_copy_end) >=
                                  R_COPY_SAFE_2X)) {
                        /*
                         * This path handles offsets 8..15. A 16-byte
                         * memcpy would overlap, so propagate forward.
                         */
                        while (out_at < out_copy_end) {
                                *out_at = *(out_at - offset);
                                ++out_at;
                        }
                } else {
                        if (!out_repeat_slow(r_bytes_max, offset, out_at,
                                             out_from, out_copy_end, out_end))
                                return LZ4K_STATUS_FAILED;
                }

                out_at = out_copy_end;
        }

        return in_at == in_end ? (int)(out_at - out) :
                                 LZ4K_STATUS_FAILED;
}

static int decode_pattern_4kb(
        const uint8_t *const in,
        uint8_t *const out,
        const uint8_t *const out_end)
{
        uint64_t pattern;
        size_t i;

        if (unlikely((size_t)(out_end - out) <
                     (1U << BLOCK_4KB_LOG2)))
                return LZ4K_STATUS_FAILED;

        m_copy(&pattern, in, sizeof(pattern));

        for (i = 0; i < (1U << BLOCK_4KB_LOG2);
             i += sizeof(pattern))
                m_copy(out + i, &pattern, sizeof(pattern));

        return 1U << BLOCK_4KB_LOG2;
}

static int decode_4kb(
	const uint8_t *const in,
	uint8_t *const out,
	const uint8_t *const in_end,
	const uint8_t *const out_end)
{
	return decode(in, out, in_end, out_end, NR_4KB_LOG2, BLOCK_4KB_LOG2);
}

int lz4kd_decode(
        const void *in,
        void *const out,
        unsigned in_max,
        unsigned out_max)
{
        unsigned out_size;
        const uint8_t *in_end;
        const uint8_t *out_end;

        if (unlikely(!in || !out))
                return LZ4K_STATUS_FAILED;

        if (unlikely(in_max <= 1 + TAG_BYTES_MAX || !out_max))
                return LZ4K_STATUS_FAILED;

        out_size = (unsigned)min_u64(
                out_max, 1U << BLOCK_4KB_LOG2);

        /*
         * Validate integer address ranges before forming end pointers.
         * The caller must still provide buffers of the declared sizes.
         */
        if (unlikely((unsigned long)in >
                     ~0UL - (unsigned long)in_max ||
                     (unsigned long)out >
                     ~0UL - (unsigned long)out_size))
                return LZ4K_STATUS_FAILED;

        in_end = (const uint8_t *)in + in_max;
        out_end = (const uint8_t *)out + out_size;

        if (unlikely(in_max == PATTERN_BYTES_MAX))
                return decode_pattern_4kb(
                        (const uint8_t *)in, (uint8_t *)out, out_end);

        return decode_4kb(
                (const uint8_t *)in + 1, (uint8_t *)out,
                in_end, out_end);
}
EXPORT_SYMBOL(lz4kd_decode);

MODULE_LICENSE("Dual BSD/GPL");
MODULE_DESCRIPTION("LZ4K decoder");
