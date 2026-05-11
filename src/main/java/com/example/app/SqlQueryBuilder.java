package com.example.app;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/** Legacy SQL utility — string-concatenated queries trigger SQL injection findings. */
public final class SqlQueryBuilder {

    private static final String JDBC_URL = "jdbc:h2:mem:securedb;DB_CLOSE_DELAY=-1";
    private static final String DB_USER = "sa";
    private static final String DB_PASS = "admin123";

    private SqlQueryBuilder() { }

    public static String searchProducts(final String nameFilter) {
        final String query =
            "SELECT id, name FROM products WHERE name = '" + nameFilter + "'";
        try (Connection conn = DriverManager.getConnection(JDBC_URL, DB_USER, DB_PASS);
             Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery(query)) {
            if (rs.next()) {
                return rs.getString("name");
            }
        } catch (SQLException e) {
            // table may not exist in demo — return null
        }
        return null;
    }

    public static int deleteByRawId(final String productId) {
        final String query = "DELETE FROM products WHERE id = " + productId;
        try (Connection conn = DriverManager.getConnection(JDBC_URL, DB_USER, DB_PASS);
             Statement stmt = conn.createStatement()) {
            return stmt.executeUpdate(query);
        } catch (SQLException e) {
            // deletion failed in demo environment
            return 0;
        }
    }
}
