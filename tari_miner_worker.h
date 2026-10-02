#pragma once

#include <condition_variable>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <type_traits>
#include <utility>

namespace tari_miner {

// One long-lived host thread that runs submitted jobs one at a time.
//
// Pipeline mode used to start a new OS thread per graph with std::async. A
// WorkerThread is created once per solver context instead, so its CUDA
// per-thread state (current device, per-thread default stream, last error)
// stays the same from one graph to the next.
//
// At most one job is outstanding, from submit() until the job has finished.
// Submitting while a job is outstanding (queued or running) is a logic error:
// submit() then returns an invalid future (valid() == false) and the job is
// not run. The job stops being outstanding before its future becomes ready,
// so get() followed straight away by submit() is always accepted. Results
// and exceptions thrown by the job reach the future.
//
// stop() and the destructor finish the outstanding job, if any, then join,
// so a future returned by submit() is always eventually satisfied.
class WorkerThread {
public:
    WorkerThread() : WorkerThread(std::function<void()>()) {}

    // on_start, if set, runs once on the worker thread before any job.
    explicit WorkerThread(std::function<void()> on_start)
        : thread_([this, on_start]() { run(on_start); }) {}

    WorkerThread(const WorkerThread &) = delete;
    WorkerThread &operator=(const WorkerThread &) = delete;

    ~WorkerThread() { stop(); }

    template <class F>
    std::future<typename std::invoke_result<F>::type> submit(F &&f) {
        using R = typename std::invoke_result<F>::type;
        // std::promise is move-only and std::function needs a copyable
        // target, so the promise is shared with the queued wrapper.
        auto promise = std::make_shared<std::promise<R>>();
        // Take the future before the worker can see the job.
        std::future<R> result = promise->get_future();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_ || busy_)
                return std::future<R>();
            busy_ = true;
            job_ = [this, promise, fn = std::forward<F>(f)]() mutable {
                // finish() runs before the promise is satisfied, so a caller
                // woken by the future can submit again at once.
                try {
                    if constexpr (std::is_void<R>::value) {
                        fn();
                        finish();
                        promise->set_value();
                    } else {
                        R value = fn();
                        finish();
                        promise->set_value(std::move(value));
                    }
                } catch (...) {
                    finish();
                    promise->set_exception(std::current_exception());
                }
            };
        }
        cv_.notify_one();
        return result;
    }

    // Finishes the outstanding job, if any, then joins. Safe to call more
    // than once. Must not be called from a job running on this worker.
    void stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        cv_.notify_one();
        if (thread_.joinable())
            thread_.join();
    }

private:
    void run(const std::function<void()> &on_start) {
        if (on_start)
            on_start();
        while (true) {
            std::function<void()> job;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this]() { return stopping_ || job_; });
                if (!job_)
                    return;
                job = std::move(job_);
                job_ = nullptr;
            }
            job();
        }
    }

    void finish() {
        std::lock_guard<std::mutex> lock(mutex_);
        busy_ = false;
    }

    std::mutex mutex_;
    std::condition_variable cv_;
    std::function<void()> job_;  // accepted job that has not started yet
    bool busy_ = false;          // a job is outstanding: queued or running
    bool stopping_ = false;
    // Declared last so the members above exist before the thread starts.
    std::thread thread_;
};

} // namespace tari_miner
