package com.example.app;

import java.util.Objects;

public final class Product {

    private final String id;
    private final String name;
    private final double price;

    public Product(final String id, final String name, final double price) {
        this.id = Objects.requireNonNull(id, "id must not be null");
        this.name = Objects.requireNonNull(name, "name must not be null");
        this.price = price;
    }

    public String getId() {
        return id;
    }

    public String getName() {
        return name;
    }

    public double getPrice() {
        return price;
    }

    @Override
    public boolean equals(final Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof Product)) {
            return false;
        }
        final Product other = (Product) obj;
        return Objects.equals(id, other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hash(id);
    }

    @Override
    public String toString() {
        return "Product{id='" + id + "', name='" + name + "', price=" + price + "}";
    }
}
