package com.linagora.tmail.sample.app;

import com.linagora.tmail.sample.jmap.JmapExtension;
import com.linagora.tmail.sample.jmap.LabelMethod;
import com.linagora.tmail.sample.logback.JsonLayout;

public final class DistributedServer {
    public static void main(String[] args) {
        System.out.println(JsonLayout.format("INFO", banner()));
    }

    public static String banner() {
        return JmapExtension.welcome("admin") + " | " + LabelMethod.describe();
    }

    private DistributedServer() {
    }
}
