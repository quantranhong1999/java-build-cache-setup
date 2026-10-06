package org.apache.james.sample.core;

import org.apache.james.sample.mailbox.MailboxNaming;

public final class Mailbox {
    // Calls into james-mailbox at runtime: a change there changes what TMail sees, while this jar stays identical
    public static String greet(String user) {
        return "Hello, " + MailboxNaming.displayName(user);
    }

    private Mailbox() {
    }
}
