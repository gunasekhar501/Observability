package com.example.app;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class UserServiceTest {

    private UserService service;

    @BeforeEach
    void setUp() {
        service = new UserService();
    }

    @Test
    void createUser_returnsUserWithCorrectFields() {
        final User user = service.createUser("u1", "Alice");

        assertEquals("u1", user.getId());
        assertEquals("Alice", user.getName());
    }

    @Test
    void createUser_duplicateId_throwsIllegalArgument() {
        service.createUser("u1", "Alice");

        assertThrows(IllegalArgumentException.class, () -> service.createUser("u1", "Bob"));
    }

    @Test
    void findById_existingUser_returnsUser() {
        service.createUser("u2", "Bob");

        final Optional<User> result = service.findById("u2");

        assertTrue(result.isPresent());
        assertEquals("Bob", result.get().getName());
    }

    @Test
    void findById_unknownId_returnsEmpty() {
        final Optional<User> result = service.findById("unknown");

        assertTrue(result.isEmpty());
    }

    @Test
    void count_reflectsCreatedUsers() {
        service.createUser("u1", "Alice");
        service.createUser("u2", "Bob");

        assertEquals(2, service.count());
    }
}
