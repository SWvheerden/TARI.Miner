#include <cmath>
#include <cstdio>
#include <fstream>
#include <limits>
#include <string>

#include "../tari_miner_stats.h"

static int failures = 0;

static void expect_rate(const char *name, double expected, double actual) {
    if (!std::isfinite(actual) || std::fabs(actual - expected) > 1e-9) {
        std::fprintf(
            stderr, "FAIL %s: expected %.6f, got %.6f\n", name, expected, actual
        );
        failures++;
    }
}

static void expect_line(const char *name, const char *expected, const std::string &actual) {
    if (actual != expected) {
        std::fprintf(
            stderr, "FAIL %s:\n  expected \"%s\"\n  got      \"%s\"\n", name,
            expected, actual.c_str()
        );
        failures++;
    }
}

int main() {
    const double window = tari_miner::SPEED_WINDOW_SEC;

    {
        tari_miner::SpeedMeter meter;
        expect_rate("empty meter", 0.0, meter.rolling_rate(window));
        meter.sample(100.0, 500);
        expect_rate("one sample", 0.0, meter.rolling_rate(window));
    }

    {
        // 10 g/s, sampled every 15 s.
        tari_miner::SpeedMeter meter;
        for (int i = 0; i <= 20; i++)
            meter.sample(15.0 * i, (uint64_t)(150 * i));
        expect_rate("steady rate", 10.0, meter.rolling_rate(window));
    }

    {
        // The pool miner samples on the first graph after 15 s, so samples are
        // a little more than 15 s apart. The window must still span four
        // intervals, not three. Each interval has a different graph count, so
        // a span of the wrong length gives a wrong rate.
        const double steps[] = {15.05, 15.3};
        for (double step : steps) {
            tari_miner::SpeedMeter meter;
            uint64_t graphs = 0;
            for (int i = 0; i <= 10; i++) {
                graphs += (uint64_t)(100 * i);
                meter.sample(step * i, graphs);
            }
            // Newest is i = 10; four intervals back is i = 6.
            const double expected = (700.0 + 800.0 + 900.0 + 1000.0) / (4 * step);
            expect_rate("jittered spacing spans four intervals", expected,
                        meter.rolling_rate(window));
        }
    }

    {
        // Uneven steps: the newest sample at least 60 s old is used.
        tari_miner::SpeedMeter meter;
        meter.sample(0.0, 0);
        meter.sample(15.2, 100);
        meter.sample(31.0, 300);
        meter.sample(46.1, 600);
        meter.sample(61.9, 1000);
        meter.sample(77.0, 1500);
        meter.sample(92.4, 2100);
        // 92.4 - 31.0 = 61.4 >= 60, while 92.4 - 46.1 = 46.3 is too young.
        expect_rate("uneven spacing", (2100.0 - 300.0) / (92.4 - 31.0),
                    meter.rolling_rate(window));
    }

    {
        // Before a full window, the rate is over the samples available.
        tari_miner::SpeedMeter meter;
        meter.sample(15.0, 100);
        meter.sample(30.0, 400);
        expect_rate("partial window", 20.0, meter.rolling_rate(window));
    }

    {
        // 10 g/s for 10 minutes, then 5 g/s. The rolling rate follows within
        // one window while the lifetime rate lags behind.
        tari_miner::SpeedMeter meter;
        double t = 0.0;
        uint64_t graphs = 0;
        meter.sample(t, graphs);
        for (int i = 0; i < 40; i++) {
            t += 15.0;
            graphs += 150;
            meter.sample(t, graphs);
        }
        for (int i = 0; i < 4; i++) {
            t += 15.0;
            graphs += 75;
            meter.sample(t, graphs);
        }
        expect_rate("step change rolling", 5.0, meter.rolling_rate(window));
        const double lifetime = tari_miner::average_rate(graphs, t);
        if (!(lifetime > 9.0)) {
            std::fprintf(stderr, "FAIL step change lifetime lags: %.6f\n", lifetime);
            failures++;
        }
    }

    {
        // Samples keep coming but no graphs are done: the rate drops to 0
        // once the window has only idle samples.
        tari_miner::SpeedMeter meter;
        for (int i = 0; i <= 8; i++)
            meter.sample(15.0 * i, (uint64_t)(150 * i));
        meter.sample(135.0, 1200);
        expect_rate("gap partly in window", 7.5, meter.rolling_rate(window));
        for (int i = 10; i <= 13; i++)
            meter.sample(15.0 * i, 1200);
        expect_rate("gap fills window", 0.0, meter.rolling_rate(window));
    }

    {
        // A long gap between two samples (disconnected, no reports) uses the
        // previous sample, so the gap shows as a low rate rather than 0 or
        // the old rate.
        tari_miner::SpeedMeter meter;
        meter.sample(0.0, 0);
        meter.sample(15.0, 150);
        meter.sample(315.0, 300);
        expect_rate("long gap", 0.5, meter.rolling_rate(window));
    }

    {
        // Ring wrap-around: many more samples than the capacity, with the
        // rate changing every sample, so a wrong index gives a wrong answer.
        tari_miner::SpeedMeter meter;
        uint64_t graphs = 0;
        for (int i = 0; i < 1000; i++) {
            graphs += (uint64_t)i;
            meter.sample(15.0 * i, graphs);
        }
        // Newest is i = 999; the window reaches back to i = 995.
        const double expected = (996.0 + 997.0 + 998.0 + 999.0) / 60.0;
        expect_rate("ring wrap-around", expected, meter.rolling_rate(window));
        if (meter.size() != tari_miner::SPEED_METER_CAPACITY) {
            std::fprintf(stderr, "FAIL ring size: %zu\n", meter.size());
            failures++;
        }
        // A window wider than the whole history uses the oldest sample kept.
        const size_t kept = tari_miner::SPEED_METER_CAPACITY;
        double sum = 0.0;
        for (size_t i = 1000 - kept + 1; i < 1000; i++)
            sum += (double)i;
        expect_rate("window larger than history", sum / (15.0 * (kept - 1)),
                    meter.rolling_rate(1e9));
    }

    {
        // The capacity covers the 60 s window at the 15 s report cadence.
        const double needed =
            tari_miner::SPEED_WINDOW_SEC / tari_miner::SPEED_REPORT_INTERVAL_SEC + 1;
        if ((double)tari_miner::SPEED_METER_CAPACITY < needed) {
            std::fprintf(stderr, "FAIL capacity too small for window\n");
            failures++;
        }
    }

    {
        // A repeated time is ignored; the next sample still counts its graphs.
        tari_miner::SpeedMeter meter;
        meter.sample(0.0, 0);
        meter.sample(15.0, 150);
        meter.sample(15.0, 999);
        expect_rate("equal time ignored", 10.0, meter.rolling_rate(window));
        meter.sample(30.0, 300);
        expect_rate("after equal time", 10.0, meter.rolling_rate(window));
    }

    {
        // A clock going backwards starts the history over.
        tari_miner::SpeedMeter meter;
        meter.sample(100.0, 0);
        meter.sample(115.0, 150);
        meter.sample(50.0, 300);
        expect_rate("clock backwards", 0.0, meter.rolling_rate(window));
        meter.sample(65.0, 600);
        expect_rate("after clock backwards", 20.0, meter.rolling_rate(window));
    }

    {
        // A graph counter going backwards starts the history over.
        tari_miner::SpeedMeter meter;
        meter.sample(0.0, 1000);
        meter.sample(15.0, 1150);
        meter.sample(30.0, 10);
        expect_rate("counter backwards", 0.0, meter.rolling_rate(window));
        meter.sample(45.0, 160);
        expect_rate("after counter backwards", 10.0, meter.rolling_rate(window));
    }

    {
        // Non-finite times are ignored and the rate is never NaN or inf.
        tari_miner::SpeedMeter meter;
        meter.sample(0.0, 0);
        meter.sample(std::numeric_limits<double>::quiet_NaN(), 50);
        meter.sample(std::numeric_limits<double>::infinity(), 50);
        meter.sample(15.0, 150);
        expect_rate("non-finite time ignored", 10.0, meter.rolling_rate(window));
        expect_rate("NaN window", 10.0,
                    meter.rolling_rate(std::numeric_limits<double>::quiet_NaN()));
        expect_rate("zero window", 10.0, meter.rolling_rate(0.0));
    }

    expect_rate("average rate", 2.5, tari_miner::average_rate(25, 10.0));
    expect_rate("average rate zero time", 0.0, tari_miner::average_rate(25, 0.0));
    expect_rate("average rate negative time", 0.0, tari_miner::average_rate(25, -1.0));

    // tests/hiveos_stats_test.sh feeds the same fixture through h-stats.sh,
    // so the miner and the HiveOS parser cannot drift apart. Run from the
    // repository root, as CI does.
    {
        std::ifstream fixture("tests/fixtures/speed_line.txt");
        std::string expected;
        if (!std::getline(fixture, expected)) {
            std::fprintf(stderr, "FAIL cannot read tests/fixtures/speed_line.txt\n");
            failures++;
        }
        if (!expected.empty() && expected.back() == '\r')
            expected.pop_back();
        expect_line(
            "speed line fixture", expected.c_str(),
            tari_miner::format_speed_line(13.649, 12.1, 7260, 12, 3, 2, 1, 1791158400, 4)
        );
    }
    expect_line(
        "speed line non-finite",
        "speed 0.00 g/s | avg 0.00 g/s | graphs=0 cycles=0 submitted=0 "
        "accepted=0 rejected=0 t=0 stale=0",
        tari_miner::format_speed_line(
            std::numeric_limits<double>::quiet_NaN(),
            std::numeric_limits<double>::infinity(), 0, 0, 0, 0, 0, -5, 0
        )
    );

    if (failures) {
        std::fprintf(stderr, "%d speed meter test(s) failed\n", failures);
        return 1;
    }
    std::puts("speed meter tests passed");
    return 0;
}
