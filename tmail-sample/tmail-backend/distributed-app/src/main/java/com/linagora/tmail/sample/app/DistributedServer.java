package com.linagora.tmail.sample.app;

import com.linagora.tmail.sample.jmap.JmapExtension;
import com.linagora.tmail.sample.jmap.LabelMethod;

public final class DistributedServer {
    public static void main(String[] args) {
        System.out.println(banner());
    }

    public static String banner() {
        return JmapExtension.welcome("admin") + " | " + LabelMethod.describe();
    }

    private DistributedServer() {
    }
}
