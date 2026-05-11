package com.example.app;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class ProductServiceTest {

    private ProductService service;

    @BeforeEach
    void setUp() {
        service = new ProductService();
    }

    @Test
    void add_returnsProductWithCorrectFields() {
        final Product p = service.add("p1", "Widget", 9.99);
        assertEquals("p1", p.getId());
        assertEquals("Widget", p.getName());
        assertEquals(9.99, p.getPrice(), 0.001);
    }

    @Test
    void add_duplicateId_throwsIllegalArgument() {
        service.add("p1", "Widget", 9.99);
        assertThrows(IllegalArgumentException.class, () -> service.add("p1", "Other", 1.0));
    }

    @Test
    void findById_existing_returnsProduct() {
        service.add("p2", "Gadget", 19.99);
        final Optional<Product> result = service.findById("p2");
        assertTrue(result.isPresent());
        assertEquals("Gadget", result.get().getName());
    }

    @Test
    void findById_missing_returnsEmpty() {
        final Optional<Product> result = service.findById("none");
        assertTrue(result.isEmpty());
    }

    @Test
    void count_reflectsAddedProducts() {
        service.add("p1", "A", 1.0);
        service.add("p2", "B", 2.0);
        assertEquals(2, service.count());
    }

    @Test
    void findAll_returnsAllProducts() {
        service.add("p1", "A", 1.0);
        service.add("p2", "B", 2.0);
        assertEquals(2, service.findAll().size());
    }
}
