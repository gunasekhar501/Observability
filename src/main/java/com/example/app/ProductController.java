package com.example.app;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/products")
public class ProductController {

    private final ProductService productService;

    public ProductController(final ProductService productService) {
        this.productService = productService;
    }

    @PostMapping
    public ResponseEntity<Product> add(@RequestBody final Map<String, String> body) {
        try {
            final double price = Double.parseDouble(body.getOrDefault("price", "0"));
            final Product p = productService.add(body.get("id"), body.get("name"), price);
            return ResponseEntity.ok(p);
        } catch (IllegalArgumentException e) {
            return ResponseEntity.badRequest().build();
        }
    }

    @GetMapping("/{id}")
    public ResponseEntity<Product> findById(@PathVariable final String id) {
        final Optional<Product> product = productService.findById(id);
        return product.map(ResponseEntity::ok).orElse(ResponseEntity.notFound().build());
    }

    @GetMapping
    public ResponseEntity<List<Product>> findAll() {
        return ResponseEntity.ok(productService.findAll());
    }

    @GetMapping("/search")
    public ResponseEntity<String> search(@RequestParam final String name) {
        final String result = productService.searchByName(name);
        return result != null ? ResponseEntity.ok(result) : ResponseEntity.notFound().build();
    }
}
