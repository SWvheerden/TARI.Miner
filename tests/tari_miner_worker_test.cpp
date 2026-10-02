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

static void test_second_queued_submit_is_rejected() {
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
    // The first job is running, so this one fills the single queue slot.
    std::future<int> queued = worker.submit([]() { return 2; });
    // The slot is now full: a third submit is a logic error.
    std::future<int> rejected = worker.submit([]() { return 3; });
    expect("running job future valid", running.valid());
    expect("queued job future valid", queued.valid());
    expect("over-full submit returns invalid future", !rejected.valid());
    release.set_value();
    expect("running job completes", running.get() == 1);
    expect("queued job completes", queued.get() == 2);
}

static void test_stop_without_pending_job() {
    tari_miner::WorkerThread worker;
    expect("job before stop", worker.submit([]() { return 1; }).get() == 1);
    worker.stop();
    worker.stop();  // second stop is a no-op
    std::future<int> after = worker.submit([]() { return 2; });
    expect("submit after stop returns invalid future", !after.valid());
}

static void test_stop_with_pending_job() {
    std::future<int> running;
    std::future<int> queued;
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
        queued = worker.submit([]() { return 11; });
        // The destructor finishes the running job and the queued one, then joins.
    }
    expect("stop finishes the current job", running_done.load());
    expect("stop result of current job", running.get() == 10);
    expect("stop runs the queued job", queued.get() == 11);
}

static void test_many_submits_use_one_thread() {
    tari_miner::WorkerThread worker;
    const std::thread::id first =
        worker.submit([]() { return std::this_thread::get_id(); }).get();
    bool same = true;
    for (int i = 0; i < 10000; i++) {
        std::thread::id id =
            worker.submit([]() { return std::this_thread::get_id(); }).get();
        if (id != first)
            same = false;
    }
    expect("thread id is stable across 10k jobs", same);
    expect("jobs do not run on the caller", first != std::this_thread::get_id());
}

int main() {
    test_runs_jobs_in_order();
    test_void_job();
    test_exception_passes_through();
    test_on_start_runs_once_on_worker();
    test_second_queued_submit_is_rejected();
    test_stop_without_pending_job();
    test_stop_with_pending_job();
    test_many_submits_use_one_thread();
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("worker thread tests passed\n");
    return 0;
}
