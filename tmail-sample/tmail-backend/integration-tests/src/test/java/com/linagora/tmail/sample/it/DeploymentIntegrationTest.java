package com.linagora.tmail.sample.it;

import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.Test;

// Like TMail's deployment-tests: loads the app image built by another module, by path, not through a Maven dependency
class DeploymentIntegrationTest {
    private static final Path APP_IMAGE = Path.of("..", "distributed-app", "target", "jib-image.tar");
    // Stands for an expensive test: the time a cache hit saves
    private static final long SIMULATED_WORK_MILLIS = 4_000;

    @Test
    void appImageShouldBeAvailable() throws Exception {
        Thread.sleep(SIMULATED_WORK_MILLIS);

        assertTrue(Files.size(APP_IMAGE) > 0, APP_IMAGE.toAbsolutePath() + " is empty");
    }
}
