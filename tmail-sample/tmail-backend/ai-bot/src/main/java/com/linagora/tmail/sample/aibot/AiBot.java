package com.linagora.tmail.sample.aibot;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.Properties;

import org.apache.james.sample.core.Mailbox;
import org.apache.james.sample.mailet.MailetNames;

public final class AiBot {
    public static String answer(String user, String question) {
        return Mailbox.greet(user) + ", you asked: " + question;
    }

    public static String mailetName() {
        return MailetNames.botMailet();
    }

    // From src/main/resources/ai-bot.properties, filtered with the root pom's ai.bot.model property
    public static String model() {
        try (InputStream input = AiBot.class.getResourceAsStream("/ai-bot.properties")) {
            Properties properties = new Properties();
            properties.load(input);
            return properties.getProperty("model");
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private AiBot() {
    }
}
