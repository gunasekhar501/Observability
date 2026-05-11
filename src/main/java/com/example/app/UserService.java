package com.example.app;

import jakarta.validation.constraints.NotBlank;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.stereotype.Service;

@Service
public class UserService {

    private final Map<String, User> userStore = new ConcurrentHashMap<>();

    public User createUser(@NotBlank final String id, @NotBlank final String name) {
        if (userStore.containsKey(id)) {
            throw new IllegalArgumentException("User already exists: " + id);
        }
        final User user = new User(id, name);
        userStore.put(id, user);
        return user;
    }

    public Optional<User> findById(final String id) {
        return Optional.ofNullable(userStore.get(id));
    }

    public int count() {
        return userStore.size();
    }
}
