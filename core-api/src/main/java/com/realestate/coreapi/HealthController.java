package com.realestate.coreapi;

import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.sql.Connection;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class HealthController {

    @Autowired
    private DataSource dataSource;

    @Autowired
    private ConnectionFactory rabbitConnectionFactory;

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        Map<String, String> result = new LinkedHashMap<>();
        boolean allOk = true;

        try (Connection conn = dataSource.getConnection()) {
            conn.createStatement().executeQuery("SELECT 1");
            result.put("db", "ok");
        } catch (Exception e) {
            result.put("db", "error: " + e.getMessage());
            allOk = false;
        }

        try {
            org.springframework.amqp.rabbit.connection.Connection mqConn =
                    rabbitConnectionFactory.createConnection();
            mqConn.close();
            result.put("mq", "ok");
        } catch (Exception e) {
            result.put("mq", "error: " + e.getMessage());
            allOk = false;
        }

        result.put("status", allOk ? "UP" : "DOWN");
        return ResponseEntity.status(allOk ? 200 : 503).body(result);
    }
}
