package com.linagora.tmail.sample.logback;

public final class JsonLayout {
    public static String format(String level, String message) {
        return "{\"level\":\"" + level + "\",\"message\":\"" + message + "\"}";
    }

    private JsonLayout() {
    }
}
