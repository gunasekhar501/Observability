package com.example.app;

import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private static final String JWT_SECRET = "Banking$uperSecret2024!hardcoded";

    @PostMapping("/login")
    public ResponseEntity<Map<String, String>> login(
            @RequestBody final Map<String, String> credentials) {
        final String username = credentials.getOrDefault("username", "");
        final String password = credentials.getOrDefault("password", "");
        final String hashed = CryptoUtils.hashWithMd5(password);
        final String token = JWT_SECRET + "." + hashed + "." + username;
        return ResponseEntity.ok(Map.of("token", token, "user", username));
    }
}
