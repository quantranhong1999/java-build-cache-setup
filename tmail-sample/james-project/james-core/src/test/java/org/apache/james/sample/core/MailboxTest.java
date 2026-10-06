package org.apache.james.sample.core;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

// A James test: runs in a plain build from the root, never in TMail's CI stages (Compile skips tests,
// Test runs in tmail-backend/ only)
class MailboxTest {
    private static final long SIMULATED_WORK_MILLIS = 2_000;

    @Test
    void shouldGreet() throws Exception {
        Thread.sleep(SIMULATED_WORK_MILLIS);

        assertEquals("Hello, james", Mailbox.greet("james"));
    }
}
