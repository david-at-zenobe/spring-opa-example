package org.example;

import io.github.open_policy_agent.opa.OPAClient;
import io.github.open_policy_agent.opa.OPAException;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;
import java.util.Map;

@RestController
public class SitesController {

    private static final String OPA_PATH = "com/zenobe/authz/users/response";

    private final Map<String, List<String>> orgSites = Map.of(
            "acme-corp", List.of("1", "2"),
            "globex", List.of("3")
    );

    private final OPAClient opa = new OPAClient("http://localhost:8181");

    @GetMapping("/sites")
    public List<String> getSites(
            // TODO: this should come from the caller's JWT rather than a query param, once auth is wired in.
            @RequestParam String user) {
        AuthzRequest request = new AuthzRequest(user);
        AuthzResponse response;
        try {
            response = opa.evaluate(OPA_PATH, request, AuthzResponse.class);
        } catch (OPAException e) {
            // OPA replies with no result at all for a user it doesn't know about (an undefined
            // rule), which the SDK surfaces as an exception rather than a null/empty response.
            // Fail closed: treat "OPA couldn't produce a decision" as "not authorized".
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "no authorization decision for user: " + user, e);
        }
        if (response == null || response.result == null) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "no authorization decision for user: " + user);
        }
        return orgSites.getOrDefault(response.result.org, List.of());
    }

    private static class AuthzRequest {
        public String user;

        public AuthzRequest(String user) {
            this.user = user;
        }
    }

    private static class AuthzResponse {
        public boolean initialised;
        public String revision;
        public AuthzResult result;
    }

    private static class AuthzResult {
        public String org;
    }
}
