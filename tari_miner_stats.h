// Small, GPU-independent miner statistics helpers.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>

namespace tari_miner {

// The pool miner samples every 15 s or more and reads a 60 s window, so five
// samples cover a full window. The extra room keeps the window covered even if
// the report cadence is shortened later.
constexpr size_t SPEED_METER_CAPACITY = 16;
constexpr double SPEED_REPORT_INTERVAL_SEC = 15.0;
constexpr double SPEED_WINDOW_SEC = 60.0;

// Rolling graph rate from (time, total graphs) samples. Holds no clock: the
// caller passes the time in, so it can be tested.
class SpeedMeter {
public:
    // A sample with a time that is not after the newest one is ignored; the
    // totals are cumulative, so the next sample still counts those graphs. A
    // clock or counter that goes backwards starts the history over.
    void sample(double t_sec, uint64_t total_graphs) {
        if (!std::isfinite(t_sec))
            return;
        if (count_ > 0) {
            const size_t newest = (next_ + SPEED_METER_CAPACITY - 1) % SPEED_METER_CAPACITY;
            if (t_sec == times_[newest])
                return;
            if (t_sec < times_[newest] || total_graphs < graphs_[newest])
                count_ = 0;
        }
        times_[next_] = t_sec;
        graphs_[next_] = total_graphs;
        next_ = (next_ + 1) % SPEED_METER_CAPACITY;
        if (count_ < SPEED_METER_CAPACITY)
            count_++;
    }

    // Rate between the newest sample and the oldest sample no more than
    // window_sec older than it. Before a full window exists this is the rate
    // over the samples available. If no older sample is inside the window (a
    // long gap between samples), the previous sample is used, so a gap with no
    // graphs shows as a low rate. Returns 0 with fewer than 2 samples.
    double rolling_rate(double window_sec) const {
        if (count_ < 2)
            return 0.0;
        const size_t newest = (next_ + SPEED_METER_CAPACITY - 1) % SPEED_METER_CAPACITY;
        size_t oldest = (newest + SPEED_METER_CAPACITY - 1) % SPEED_METER_CAPACITY;
        for (size_t back = 2; back < count_; back++) {
            const size_t i = (newest + SPEED_METER_CAPACITY - back) % SPEED_METER_CAPACITY;
            if (!(times_[newest] - times_[i] <= window_sec))
                break;
            oldest = i;
        }
        const double elapsed = times_[newest] - times_[oldest];
        if (!(elapsed > 0.0))
            return 0.0;
        const double rate = (double)(graphs_[newest] - graphs_[oldest]) / elapsed;
        return std::isfinite(rate) ? rate : 0.0;
    }

    size_t size() const { return count_; }

private:
    double times_[SPEED_METER_CAPACITY] = {};
    uint64_t graphs_[SPEED_METER_CAPACITY] = {};
    size_t next_ = 0;
    size_t count_ = 0;
};

// Graphs per second since start, or 0 before any time has passed.
inline double average_rate(uint64_t graphs, double elapsed_sec) {
    if (!(elapsed_sec > 0.0))
        return 0.0;
    const double rate = (double)graphs / elapsed_sec;
    return std::isfinite(rate) ? rate : 0.0;
}

// The periodic report line, without the trailing newline. hiveos/h-stats.sh
// reads the number after "speed" and the accepted=/rejected= counters.
inline std::string format_speed_line(
    double rolling,
    double lifetime,
    uint64_t graphs,
    uint64_t cycles,
    uint64_t submitted,
    uint64_t accepted,
    uint64_t rejected
) {
    if (!std::isfinite(rolling) || rolling < 0.0) rolling = 0.0;
    if (!std::isfinite(lifetime) || lifetime < 0.0) lifetime = 0.0;
    char line[256];
    std::snprintf(
        line, sizeof(line),
        "speed %.2f g/s | avg %.2f g/s | graphs=%llu cycles=%llu submitted=%llu "
        "accepted=%llu rejected=%llu",
        rolling, lifetime, (unsigned long long)graphs, (unsigned long long)cycles,
        (unsigned long long)submitted, (unsigned long long)accepted,
        (unsigned long long)rejected
    );
    return line;
}

} // namespace tari_miner
