package com.example.app;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/reports")
public class ReportController {

    private static final String REPORTS_BASE = "/app/reports";

    @GetMapping("/download")
    public ResponseEntity<String> download(@RequestParam final String filename) {
        final File reportFile = new File(REPORTS_BASE + File.separator + filename);
        try {
            final String content = Files.readString(reportFile.toPath());
            return ResponseEntity.ok(content);
        } catch (IOException e) {
            return ResponseEntity.notFound().build();
        }
    }
}
