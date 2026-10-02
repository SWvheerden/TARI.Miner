#include <atomic>
#include <chrono>
#include <cstdio>
#include <future>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "../tari_miner_worker.h"

static int failures = 0;

static void expect(const char *name, bool ok) {
    if (!ok) {
        std::fprintf(stderr, "FAIL %s\n", name);
        failures++;
    }
}

static void test_runs_jobs_in_order() {
    tari_miner::WorkerThread worker;
    std::vector<int> order;
    for (int i = 0; i < 100; i++) {
        std::future<int> f = worker.submit([&order, i]() {
            order.push_back(i);
            return i * 2;
        });
        expect("returns value through future", f.get() == i * 2);
    }
    bool in_order = order.size() == 100;
    for (int i = 0; in_order && i < 100; i++)
        in_order = order[(size_t)i] == i;
    expect("runs jobs in order", in_order);
}

static void test_void_job() {
    tari_miner::WorkerThread worker;
    bool ran = false;
    std::future<void> f = worker.submit([&ran]() { ran = true; });
    f.get();
    expect("void job runs", ran);
}

static void test_exception_passes_through() {
    tari_miner::WorkerThread worker;
    std::future<int> f = worker.submit([]() -> int {
        throw std::runtime_error("job failed");
    });
    bool caught = false;
    try {
        (void)f.get();
    } catch (const std::runtime_error &e) {
        caught = std::string(e.what()) == "job failed";
    }
    expect("exception reaches future", caught);

    // The worker keeps running after a job throws.
    std::future<int> next = worker.submit([]() { return 7; });
    expect("worker survives exception", next.get() == 7);
}

static void test_on_start_runs_once_on_worker() {
    std::atomic<int> starts{0};
    std::thread::id start_id;
    tari_miner::WorkerThread worker([&starts, &start_id]() {
        start_id = std::this_thread::get_id();
        starts++;
    });
    std::thread::id job_id;
    for (int i = 0; i < 10; i++)
        job_id = worker.submit([]() { return std::this_thread::get_id(); }).get();
    expect("on_start runs once", starts.load() == 1);
    expect("on_start runs on worker thread", start_id == job_id);
    expect("worker is not the caller", job_id != std::this_thread::get_id());
}

static void test_submit_while_running_is_rejected() {
    tari_miner::WorkerThread worker;
    std::promise<void> release;
    std::shared_future<void> gate = release.get_future().share();
    std::promise<void> started;
    std::future<void> started_f = started.get_future();

    std::future<int> running = worker.submit([&started, gate]() {
        started.set_value();
        gate.wait();
        return 1;
    });
    started_f.get();
    // The first job is still running, so it is outstanding.
    std::future<int> rejected = worker.submit([]() { return 2; });
    expect("running job future valid", running.valid());
    expect("submit while running returns invalid future", !rejected.valid());
    release.set_value();
    expect("running job completes", running.get() == 1);
    std::future<int> next = worker.submit([]() { return 3; });
    expect("submit after the job finished is accepted", next.valid());
    expect("next job completes", next.get() == 3);
}

static void test_submit_while_queued_is_rejected() {
    // A job that has not started yet is outstanding too. Hold the worker in
    // on_start so the first job stays queued.
    std::promise<void> release;
    std::shared_future<void> gate = release.get_future().share();
    tari_miner::WorkerThread worker([gate]() { gate.wait(); });
    std::future<int> queued = worker.submit([]() { return 1; });
    std::future<int> rejected = worker.submit([]() { return 2; });
    expect("queued job future valid", queued.valid());
    expect("submit while queued returns invalid future", !rejected.valid());
    release.set_value();
    expect("queued job completes", queued.get() == 1);
}

static void test_stop_without_pending_job() {
    tari_miner::WorkerThread worker;
    expect("job before stop", worker.submit([]() { return 1; }).get() == 1);
    worker.stop();
    worker.stop();  // second stop is a no-op
    std::future<int> after = worker.submit([]() { return 2; });
    expect("submit after stop returns invalid future", !after.valid());
}

static void test_stop_with_running_job() {
    std::future<int> running;
    std::atomic<bool> running_done{false};
    {
        tari_miner::WorkerThread worker;
        std::promise<void> started;
        std::future<void> started_f = started.get_future();
        running = worker.submit([&started, &running_done]() {
            started.set_value();
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            running_done = true;
            return 10;
        });
        started_f.get();
        // The destructor finishes the running job, then joins.
    }
    expect("stop finishes the current job", running_done.load());
    expect("stop result of current job", running.get() == 10);
}

static void test_exception_clears_outstanding() {
    tari_miner::WorkerThread worker;
    for (int i = 0; i < 1000; i++) {
        std::future<int> f = worker.submit([]() -> int {
            throw std::runtime_error("job failed");
        });
        bool caught = false;
        try {
            (void)f.get();
        } catch (const std::runtime_error &) {
            caught = true;
        }
        if (!caught) {
            expect("exception reaches future in loop", false);
            return;
        }
    }
    std::future<int> next = worker.submit([]() { return 5; });
    expect("submit straight after a thrown job is accepted", next.valid() && next.get() == 5);
}

static void test_many_submits_use_one_thread() {
    tari_miner::WorkerThread worker;
    const std::thread::id first =
        worker.submit([]() { return std::this_thread::get_id(); }).get();
    bool same = true;
    bool all_valid = true;
    for (int i = 0; i < 10000; i++) {
        // get() followed straight away by submit() must never be rejected.
        std::future<std::thread::id> f =
            worker.submit([]() { return std::this_thread::get_id(); });
        if (!f.valid()) {
            all_valid = false;
            break;
        }
        if (f.get() != first)
            same = false;
    }
    expect("submit right after get() is always accepted", all_valid);
    expect("thread id is stable across 10k jobs", same);
    expect("jobs do not run on the caller", first != std::this_thread::get_id());
}

int main() {
    test_runs_jobs_in_order();
    test_void_job();
    test_exception_passes_through();
    test_on_start_runs_once_on_worker();
    test_submit_while_running_is_rejected();
    test_submit_while_queued_is_rejected();
    test_stop_without_pending_job();
    test_stop_with_running_job();
    test_exception_clears_outstanding();
    test_many_submits_use_one_thread();
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("worker thread tests passed\n");
    return 0;
}
