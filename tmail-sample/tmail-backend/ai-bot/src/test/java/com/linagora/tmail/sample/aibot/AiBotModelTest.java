package com.linagora.tmail.sample.aibot;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class AiBotModelTest {
    @Test
    void modelComesFromTheRootPom() {
        assertEquals("gpt", AiBot.model());
    }
}
