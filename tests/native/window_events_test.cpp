// The scripted-input timeline (src/compose_ui/window_events.h) with no
// window: two windows following window_events_test.input, polled the way the
// window loop polls them. Run by `zig build test` with KLIO_WIN_INPUT set.

#include <chrono>
#include <cstdio>
#include <deque>
#include <thread>

#include "window_events.h"

static int failures = 0;

static void check(bool ok, const char* what) {
    if (ok) return;
    std::fprintf(stderr, "window_events_test: %s\n", what);
    failures++;
}

// The windows take the script's events in the order they fall due even when
// the whole window loop stalls past every event and past the wait's cap: a
// window still polled is waited for, however late its events run.
static void stalledLoopKeepsOrder() {
    KlioScriptState first;
    KlioScriptState second;
    std::deque<KlioEv> q1, q2;
    klioScriptTick(first, q1);
    klioScriptTick(second, q2);
    check(q1.empty() && q2.empty(), "no event is due at the origin");

    std::this_thread::sleep_for(std::chrono::milliseconds(1300));

    // The first window takes its 100 ms event (the second's falls due at the
    // same time, and the first was made first), not its 200 ms one: the
    // second window's 100 ms event comes before it.
    klioScriptTick(first, q1);
    check(q1.size() == 1, "after a stall the first window takes only the event no other window's precedes");

    // The second window waits for the effect of the first's event, then
    // takes its own 100 ms one.
    klioScriptTick(second, q2);
    check(q2.empty(), "the second window waits for the first window's frame");
    klioScriptFramed(first);
    klioScriptTick(second, q2);
    check(q2.size() == 1, "the second window then takes its 100 ms event");

    klioScriptFramed(second);
    klioScriptTick(first, q1);
    check(q1.size() == 2, "the first window then takes its 200 ms event");
    klioScriptFramed(first);
    klioScriptTick(second, q2);
    check(q2.size() == 2, "and the second window its own");
}

int main() {
    if (klioScript().empty()) {
        std::fprintf(stderr, "window_events_test: KLIO_WIN_INPUT names no script\n");
        return 1;
    }
    stalledLoopKeepsOrder();
    return failures == 0 ? 0 : 1;
}
