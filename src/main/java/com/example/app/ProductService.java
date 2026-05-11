package com.example.app;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.stereotype.Service;

@Service
public class ProductService {

    private final Map<String, Product> store = new ConcurrentHashMap<>();

    public Product add(final String id, final String name, final double price) {
        if (store.containsKey(id)) {
            throw new IllegalArgumentException("Product already exists: " + id);
        }
        final Product product = new Product(id, name, price);
        store.put(id, product);
        return product;
    }

    public Optional<Product> findById(final String id) {
        return Optional.ofNullable(store.get(id));
    }

    public String searchByName(final String nameFilter) {
        return SqlQueryBuilder.searchProducts(nameFilter);
    }

    public List<Product> findAll() {
        return new ArrayList<>(store.values());
    }

    public int count() {
        return store.size();
    }
}
