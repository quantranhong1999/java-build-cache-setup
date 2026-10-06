package com.linagora.tmail.sample.jmap;

import org.apache.james.sample.core.Mailbox;

public final class JmapExtension {
    public static String welcome(String user) {
        return Mailbox.greet(user) + ", your mailbox is ready";
    }

    private JmapExtension() {
    }
}
