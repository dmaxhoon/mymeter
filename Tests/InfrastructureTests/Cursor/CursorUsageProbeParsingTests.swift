import Foundation
import Testing
@testable import Infrastructure
@testable import Domain

@Suite("CursorUsageProbe Parsing Tests")
struct CursorUsageProbeParsingTests {

    // MARK: - Real API Response

    @Test
    func `parse real ultra plan response`() throws {
        // Actual response from cursor.com/api/usage-summary
        let json = """
        {
            "billingCycleStart": "2026-02-06T03:34:49.000Z",
            "billingCycleEnd": "2026-03-06T03:34:49.000Z",
            "membershipType": "ultra",
            "limitType": "user",
            "isUnlimited": false,
            "autoModelSelectedDisplayMessage": "You've used 1% of your included total usage",
            "namedModelSelectedDisplayMessage": "You've used 1% of your included API usage",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 326,
                    "limit": 40000,
                    "remaining": 39674,
                    "breakdown": { "included": 40000, "bonus": 0, "total": 40000 },
                    "autoPercentUsed": 0.033,
                    "apiPercentUsed": 0.586,
                    "totalPercentUsed": 0.815
                },
                "onDemand": {
                    "enabled": false,
                    "used": 0,
                    "limit": null,
                    "remaining": null
                }
            },
            "teamUsage": {}
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.providerId == "cursor")
        #expect(snapshot.accountTier == .custom("ULTRA"))

        // Both pools are reported, so the dashboard-style split replaces the combined total.
        #expect(snapshot.quotas.map(\.quotaType) == [.modelSpecific("Cursor Models"), .modelSpecific("Other Models")])
        #expect(abs(snapshot.quotas[0].percentRemaining - 99.967) < 0.01)
        #expect(abs(snapshot.quotas[1].percentRemaining - 99.414) < 0.01)
        #expect(snapshot.quotas[0].resetsAt != nil)
    }

    /// Cursor's dashboard splits the included allotment into "Cursor Models"
    /// (`autoPercentUsed`) and "Other Models" (`apiPercentUsed`). Mirror both.
    @Test
    func `parse ultra plan exposes Cursor Models and Other Models breakdown`() throws {
        let json = """
        {
            "billingCycleStart": "2026-08-16T18:08:44.000Z",
            "billingCycleEnd": "2026-09-16T18:08:44.000Z",
            "membershipType": "ultra",
            "limitType": "user",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 20927,
                    "limit": 40000,
                    "remaining": 19073,
                    "breakdown": { "included": 20927, "bonus": 0, "total": 20927 },
                    "autoPercentUsed": 3.4453333333333336,
                    "apiPercentUsed": 21.182000000000002,
                    "totalPercentUsed": 5.9791428571428575
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            },
            "teamUsage": {}
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        // Matches cursor.com/dashboard, which shows the two pools and no combined total.
        #expect(snapshot.quotas.map(\.quotaType) == [
            .modelSpecific("Cursor Models"),
            .modelSpecific("Other Models"),
        ])

        let cursorModels = try #require(snapshot.quota(for: .modelSpecific("Cursor Models")))
        #expect(abs(cursorModels.percentRemaining - 96.555) < 0.01)
        #expect(cursorModels.resetText == "Includes Cursor Grok and Composer")
        #expect(cursorModels.resetsAt != nil)

        let otherModels = try #require(snapshot.quota(for: .modelSpecific("Other Models")))
        #expect(abs(otherModels.percentRemaining - 78.818) < 0.01)
        #expect(otherModels.resetText == nil)
        #expect(otherModels.resetsAt == cursorModels.resetsAt)
    }

    @Test
    func `model breakdown is omitted when the API does not report it`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": { "enabled": true, "used": 123, "limit": 500, "remaining": 377 },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.map(\.quotaType) == [.timeLimit("Monthly")])
    }

    @Test
    func `model breakdown clamps over-limit usage to zero remaining`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true, "used": 500, "limit": 500, "remaining": 0,
                    "autoPercentUsed": 12.5, "apiPercentUsed": 140.2, "totalPercentUsed": 100
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quota(for: .modelSpecific("Other Models"))?.percentRemaining == 0)
        #expect(snapshot.quota(for: .timeLimit("Monthly")) == nil)
    }

    @Test
    func `monthly total is kept when only one pool percentage is reported`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": { "enabled": true, "used": 100, "limit": 500, "remaining": 400, "apiPercentUsed": 20 },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.map(\.quotaType) == [.timeLimit("Monthly"), .modelSpecific("Other Models")])
    }

    // MARK: - Plan Usage

    @Test
    func `parse pro plan with plan usage`() throws {
        let json = """
        {
            "membershipType": "pro",
            "billingCycleEnd": "2025-02-01T00:00:00Z",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 123,
                    "limit": 500,
                    "remaining": 377
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.providerId == "cursor")
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.accountTier == .custom("PRO"))

        let quota = snapshot.quotas[0]
        #expect(quota.quotaType == .timeLimit("Monthly"))
        #expect(abs(quota.percentRemaining - 75.4) < 0.1)
        #expect(quota.resetText == "123/500 requests")
        #expect(quota.resetsAt != nil)
    }

    @Test
    func `parse plan with on-demand usage enabled`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 400,
                    "limit": 500,
                    "remaining": 100
                },
                "onDemand": {
                    "enabled": true,
                    "used": 25,
                    "limit": 100,
                    "remaining": 75
                }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.count == 2)

        let plan = snapshot.quotas.first { $0.quotaType == .timeLimit("Monthly") }
        #expect(plan != nil)
        #expect(abs(plan!.percentRemaining - 20.0) < 0.1)
        #expect(plan!.resetText == "400/500 requests")

        let onDemand = snapshot.quotas.first { $0.quotaType == .timeLimit("On-Demand") }
        #expect(onDemand != nil)
        #expect(abs(onDemand!.percentRemaining - 75.0) < 0.1)
    }

    @Test
    func `parse depleted plan usage`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 500,
                    "limit": 500,
                    "remaining": 0
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].percentRemaining == 0)
        #expect(snapshot.quotas[0].resetText == "500/500 requests")
    }

    @Test
    func `parse pro plan with bonus credits reports remaining from total capacity`() throws {
        // Regression: a Pro user with bonus credits. The `used`/`limit` fields describe
        // only the *included* base (2000/2000 = maxed), but `breakdown.total` shows the
        // real capacity (9770 incl. 7770 bonus) and `totalPercentUsed` shows true usage
        // (28.32%). The old logic derived percentRemaining from used/limit -> 0% -> EMPTY.
        // Correct behavior: ~71.68% remaining, NOT depleted.
        let json = """
        {
            "billingCycleStart": "2026-06-25T03:47:17.000Z",
            "billingCycleEnd": "2026-07-25T03:47:17.000Z",
            "membershipType": "pro",
            "limitType": "user",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 2000,
                    "limit": 2000,
                    "remaining": 0,
                    "breakdown": { "included": 2000, "bonus": 7770, "total": 9770 },
                    "totalPercentUsed": 28.32
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            },
            "teamUsage": {}
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        // No per-pool percentages here, so the combined Monthly total is what gets shown.
        #expect(snapshot.quotas.count == 1)
        let quota = snapshot.quotas[0]
        #expect(quota.quotaType == .timeLimit("Monthly"))
        // 28.32% used of the full 9770 capacity -> 71.68% remaining (was incorrectly 0)
        #expect(abs(quota.percentRemaining - 71.68) < 0.1)
        #expect(quota.resetText == "2767/9770 requests")
    }

    @Test
    func `parse over-limit usage clamps to zero`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 550,
                    "limit": 500,
                    "remaining": -50
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].percentRemaining == 0)
    }

    // MARK: - Unlimited & Special Cases

    @Test
    func `parse unlimited plan`() throws {
        let json = """
        {
            "membershipType": "business",
            "isUnlimited": true,
            "individualUsage": {
                "plan": { "enabled": false },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].percentRemaining == 100)
        #expect(snapshot.quotas[0].resetText == "Unlimited")
        #expect(snapshot.accountTier == .custom("BUSINESS"))
    }

    @Test
    func `parse free plan`() throws {
        let json = """
        {
            "membershipType": "free",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 30,
                    "limit": 50,
                    "remaining": 20
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.accountTier == .custom("FREE"))
        #expect(snapshot.quotas.count == 1)
        #expect(abs(snapshot.quotas[0].percentRemaining - 40.0) < 0.1)
    }

    // MARK: - Enterprise Plan

    @Test
    func `parse enterprise plan with team limitType`() throws {
        let json = """
        {
            "billingCycleStart": "2026-03-01T00:00:00.000Z",
            "billingCycleEnd": "2026-04-01T00:00:00.000Z",
            "membershipType": "enterprise",
            "limitType": "team",
            "isUnlimited": false,
            "autoModelSelectedDisplayMessage": "You've used 7% of your included total usage",
            "namedModelSelectedDisplayMessage": "You've used 7% of your included API usage",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 0,
                    "limit": 0,
                    "remaining": 0,
                    "breakdown": {
                        "included": 0,
                        "bonus": 300,
                        "total": 300
                    },
                    "autoPercentUsed": 0,
                    "apiPercentUsed": 6.9,
                    "totalPercentUsed": 6.9
                },
                "onDemand": {
                    "enabled": false,
                    "used": 0,
                    "limit": 0,
                    "remaining": 0
                }
            },
            "teamUsage": {
                "onDemand": {
                    "enabled": true,
                    "used": 0,
                    "limit": 10000,
                    "remaining": 10000
                }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.providerId == "cursor")
        #expect(snapshot.accountTier == .custom("ENTERPRISE"))

        // Cursor Models / Other Models pools (the combined total is dropped) + team quota
        #expect(snapshot.quotas.map(\.quotaType) == [
            .modelSpecific("Cursor Models"),
            .modelSpecific("Other Models"),
            .timeLimit("Team"),
        ])
        // 6.9% of Other Models used -> 93.1% remaining
        #expect(abs(snapshot.quotas[1].percentRemaining - 93.1) < 0.01)

        let teamQuota = snapshot.quotas.first { $0.quotaType == .timeLimit("Team") }
        #expect(teamQuota != nil)
        #expect(teamQuota!.percentRemaining == 100.0)
        #expect(teamQuota!.resetText == "0/10000 team credits")
    }

    @Test
    func `parse enterprise plan individual usage falls back to breakdown total`() throws {
        let json = """
        {
            "membershipType": "enterprise",
            "limitType": "team",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 0,
                    "limit": 0,
                    "remaining": 0,
                    "breakdown": {
                        "included": 0,
                        "bonus": 184,
                        "total": 184
                    },
                    "totalPercentUsed": 50.0
                },
                "onDemand": { "enabled": false, "used": 0, "limit": 0, "remaining": 0 }
            },
            "teamUsage": {
                "onDemand": { "enabled": false, "used": 0, "limit": 0, "remaining": 0 }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.count == 1)
        let quota = snapshot.quotas[0]
        #expect(quota.quotaType == .timeLimit("Monthly"))
        // 50% used -> 50% remaining
        #expect(abs(quota.percentRemaining - 50.0) < 0.5)
    }

    // MARK: - Error Cases

    @Test
    func `parse empty response throws error`() {
        let json = "{}".data(using: .utf8)!

        #expect(throws: ProbeError.self) {
            try CursorUsageProbe.parseUsageSummary(json)
        }
    }

    @Test
    func `parse invalid json throws error`() {
        let json = "not json".data(using: .utf8)!

        #expect(throws: ProbeError.self) {
            try CursorUsageProbe.parseUsageSummary(json)
        }
    }

    @Test
    func `parse response with no individualUsage and not unlimited throws error`() {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false
        }
        """.data(using: .utf8)!

        #expect(throws: ProbeError.self) {
            try CursorUsageProbe.parseUsageSummary(json)
        }
    }

    // MARK: - Billing Cycle

    @Test
    func `parse billing cycle end with fractional seconds`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "billingCycleEnd": "2025-03-01T00:00:00.000Z",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 100,
                    "limit": 500,
                    "remaining": 400
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)
        #expect(snapshot.quotas[0].resetsAt != nil)
    }

    @Test
    func `parse billing cycle end without fractional seconds`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "billingCycleEnd": "2025-03-01T00:00:00Z",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 100,
                    "limit": 500,
                    "remaining": 400
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)
        #expect(snapshot.quotas[0].resetsAt != nil)
    }

    // MARK: - JWT Parsing

    @Test
    func `extract user ID from valid JWT`() throws {
        // JWT with payload: {"sub": "user_abc123", "iat": 1234567890}
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJzdWIiOiJ1c2VyX2FiYzEyMyIsImlhdCI6MTIzNDU2Nzg5MH0"
        let signature = "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let jwt = "\(header).\(payload).\(signature)"

        let userId = try CursorUsageProbe.extractUserIdFromJWT(jwt)
        #expect(userId == "user_abc123")
    }

    @Test
    func `extract user ID with pipe character like real Cursor JWTs`() throws {
        // Cursor JWTs have sub like "github|user_01J6BBEPT2KSQKPPRGXDY8M1F4"
        // Payload: {"sub": "github|user_01ABC", "type": "session"}
        // base64url of {"sub":"github|user_01ABC","type":"session"} =
        let payloadJson = #"{"sub":"github|user_01ABC","type":"session"}"#
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.\(payloadBase64).sig"

        let userId = try CursorUsageProbe.extractUserIdFromJWT(jwt)
        #expect(userId == "github|user_01ABC")
    }

    @Test
    func `extract user ID from JWT with padding needed`() throws {
        // Payload: {"sub": "u1"}
        let header = "eyJhbGciOiJIUzI1NiJ9"
        let payload = "eyJzdWIiOiJ1MSJ9"
        let jwt = "\(header).\(payload).sig"

        let userId = try CursorUsageProbe.extractUserIdFromJWT(jwt)
        #expect(userId == "u1")
    }

    @Test
    func `extract user ID from invalid JWT throws`() {
        #expect(throws: ProbeError.self) {
            try CursorUsageProbe.extractUserIdFromJWT("not-a-jwt")
        }
    }

    @Test
    func `extract user ID from JWT without sub claim throws`() {
        // Payload: {"iat": 123} (no sub)
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpYXQiOjEyM30.sig"

        #expect(throws: ProbeError.self) {
            try CursorUsageProbe.extractUserIdFromJWT(jwt)
        }
    }

    // MARK: - Numeric Type Handling

    @Test
    func `parse usage values as doubles`() throws {
        // Some API responses return numbers as doubles
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 123.0,
                    "limit": 500.0,
                    "remaining": 377.0
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)

        #expect(snapshot.quotas.count == 1)
        #expect(abs(snapshot.quotas[0].percentRemaining - 75.4) < 0.1)
    }

    // MARK: - Account Tier Detection

    @Test
    func `detect ultra tier`() throws {
        let json = """
        {
            "membershipType": "ultra",
            "isUnlimited": false,
            "individualUsage": {
                "plan": { "enabled": true, "used": 1, "limit": 40000, "remaining": 39999 },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json)
        #expect(snapshot.accountTier == .custom("ULTRA"))
    }

    @Test
    func `parseUsageSummary includes account email when provided`() throws {
        let json = """
        {
            "membershipType": "pro",
            "isUnlimited": false,
            "individualUsage": {
                "plan": { "enabled": true, "used": 1, "limit": 500, "remaining": 499 },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CursorUsageProbe.parseUsageSummary(json, accountEmail: "user@example.com")

        #expect(snapshot.accountEmail == "user@example.com")
    }
}
