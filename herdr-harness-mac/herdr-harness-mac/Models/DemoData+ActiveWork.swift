import Foundation

extension DemoData {
    static var activeWork: ActiveWorkResponse {
        // Decode the demo through the production wire contract. This keeps the
        // gallery useful while also exercising every relationship the live
        // server sends to the Mac app.
        let data = Data(activeWorkJSON.utf8)
        return (try? JSONDecoder().decode(ActiveWorkResponse.self, from: data)) ?? .empty
    }

    private static let activeWorkJSON = #"""
    {
      "ok": true,
      "generated_at": "2030-01-01T22:30:00.000Z",
      "pipeline": {
        "id": "pipeline_buzz_feature_work_v1",
        "slug": "buzz-feature-work",
        "version": 1,
        "title": "Buzz Feature Work",
        "stages": [
          {"id":"s1","stage_key":"start-ticket","sequence":1,"phase_key":"open","title":"Start Ticket","short_title":"Start","skill_name":"buzz-start-ticket","checkpoint_kind":"none"},
          {"id":"s2","stage_key":"plan","sequence":2,"phase_key":"open","title":"Plan","short_title":"Plan","skill_name":"buzz-plan","checkpoint_kind":"human"},
          {"id":"s3","stage_key":"implement","sequence":3,"phase_key":"build","title":"Implement","short_title":"Build","skill_name":"buzz-implement","checkpoint_kind":"none"},
          {"id":"s4","stage_key":"architect-code-review","sequence":4,"phase_key":"build","title":"Architect Code Review","short_title":"Architect","skill_name":"buzz-architect-code-review","checkpoint_kind":"none"},
          {"id":"s5","stage_key":"proof","sequence":5,"phase_key":"prove","title":"Proof","short_title":"Proof","skill_name":"buzz-proof","checkpoint_kind":"human"},
          {"id":"s6","stage_key":"code-review-pre-pr","sequence":6,"phase_key":"prove","title":"Code Review Pre PR","short_title":"Pre PR","skill_name":"buzz-code-review-pre-pr","checkpoint_kind":"human"},
          {"id":"s7","stage_key":"pr","sequence":7,"phase_key":"ship","title":"PR","short_title":"PR","skill_name":"buzz-pr","checkpoint_kind":"human"},
          {"id":"s8","stage_key":"pr-triage","sequence":8,"phase_key":"ship","title":"PR Triage","short_title":"Triage","skill_name":"buzz-pr-triage","checkpoint_kind":"none"}
        ]
      },
      "items": [
        {
          "id": "work_demo_garden",
          "kind": "feature",
          "title": "Fictional garden seed catalog",
          "summary": "Arrange basil, thyme, and marigold in an invented three-bed garden.",
          "lifecycle": "active",
          "current_stage_key": "architect-code-review",
          "next_action": "The sample reviewer is checking the fictional seed list.",
          "revision": 18,
          "needs_attention": false,
          "setup_state": "ready",
          "updated_at": "2030-01-01T22:18:00.000Z",
          "jira_links": [{"id":"jira_1","site":"example.atlassian.net","issue_key":"DEMO-101","title":"Fictional garden seed catalog","status":"In Progress","priority":"High","issue_type":"Story","url":"https://example.atlassian.net/browse/DEMO-101"}],
          "buzz_channels": [{"id":"channel_1","source":"buzz","external_id":"00000000-0000-4000-8000-000000000001","name":"DEMO-101 fictional-garden-seed-catalog","status":"active","last_activity_at":"2030-01-01T22:17:00.000Z"}],
          "agents": [
            {"id":"agent_driver","source":"buzz","external_id":"driver","display_name":"Garden Helper","kind":"agent","role_label":"driver","status":"working","stage_links":[{"stage_key":"implement","link_role":"driver","link_state":"done"},{"stage_key":"architect-code-review","link_role":"driver","link_state":"active"}]},
            {"id":"agent_architect","source":"buzz","external_id":"architect","display_name":"Sample Reviewer","kind":"agent","role_label":"architect","status":"working","stage_links":[{"stage_key":"plan","link_role":"reviewer","link_state":"done"},{"stage_key":"architect-code-review","link_role":"reviewer","link_state":"active"}]},
            {"id":"agent_pm","source":"buzz","external_id":"pm","display_name":"Demo Coordinator","kind":"agent","role_label":"orchestrator","status":"idle","stage_links":[{"stage_key":"start-ticket","link_role":"orchestrator","link_state":"done"},{"stage_key":"proof","link_role":"orchestrator","link_state":"queued"}]}
          ],
          "pi_sessions": [{"id":"session_1","source":"herdr","external_id":"w1:p1","title":"Example seed catalog","provider":"pi","model":"claude-sonnet","status":"running","workspace_id":"w1","pane_id":"w1:p1","stage_links":[{"stage_key":"implement","link_role":"execution"},{"stage_key":"architect-code-review","link_role":"review"}]}],
          "stages": [
            {"id":"s1","stage_key":"start-ticket","state":"complete","attention":"none","checkpoint_state":"none","summary":"Ticket, channel, manifest, and driver are ready.","agents":[{"id":"agent_pm","display_name":"Demo Coordinator","role_label":"orchestrator","status":"done","link_role":"orchestrator"}],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s2","stage_key":"plan","state":"complete","attention":"none","checkpoint_state":"approved","summary":"Example plan approved with three imaginary garden beds.","agents":[{"id":"agent_architect","display_name":"Sample Reviewer","role_label":"architect","status":"done","link_role":"reviewer"}],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s3","stage_key":"implement","state":"complete","attention":"none","checkpoint_state":"none","summary":"Implementation committed and focused tests are green.","agents":[{"id":"agent_driver","display_name":"Garden Helper","role_label":"driver","status":"done","link_role":"driver"}],"pi_sessions":[{"id":"session_1","title":"Example seed catalog","provider":"pi","status":"completed","workspace_id":"w1","pane_id":"w1:p1","link_role":"execution"}],"buzz_threads":[]},
            {"id":"s4","stage_key":"architect-code-review","state":"active","attention":"agent","checkpoint_state":"none","summary":"Architecture review is running.","agents":[{"id":"agent_driver","display_name":"Garden Helper","role_label":"driver","status":"working","link_role":"driver"},{"id":"agent_architect","display_name":"Sample Reviewer","role_label":"architect","status":"working","link_role":"reviewer"}],"pi_sessions":[{"id":"session_1","title":"Example seed catalog","provider":"pi","status":"running","workspace_id":"w1","pane_id":"w1:p1","link_role":"review"}],"buzz_threads":[{"id":"thread_1","source":"buzz","external_id":"thread-root","title":"Architecture review discussion","url":"buzz://message?channel=00000000-0000-4000-8000-000000000001&id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"active","last_activity_at":"2030-01-01T22:17:00.000Z"}]},
            {"id":"s5","stage_key":"proof","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[{"id":"agent_pm","display_name":"Demo Coordinator","role_label":"orchestrator","status":"idle","link_role":"orchestrator"}],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s6","stage_key":"code-review-pre-pr","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s7","stage_key":"pr","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s8","stage_key":"pr-triage","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]}
          ],
          "activity": [
            {"id":"a1","stage_key":"architect-code-review","kind":"agent_update","actor_kind":"agent","message":"Architect review started with the approved plan and implementation diff.","source":"buzz","occurred_at":"2030-01-01T22:17:00.000Z"},
            {"id":"a2","stage_key":"implement","kind":"stage_transition","actor_kind":"agent","message":"Implementation completed and moved to architecture review.","source":"buzz","occurred_at":"2030-01-01T21:42:00.000Z"}
          ]
        },
        {
          "id": "work_demo_reading",
          "kind": "idea",
          "title": "Fictional reading journal theme",
          "summary": "Choose colors for an invented reading journal with three imaginary books.",
          "lifecycle": "active",
          "current_stage_key": "plan",
          "next_action": "Choose the sample notebook color palette.",
          "revision": 7,
          "needs_attention": true,
          "attention_reason": "Plan approval",
          "setup_state": "channel_linked",
          "updated_at": "2030-01-01T21:55:00.000Z",
          "buzz_channels": [{"id":"channel_2","source":"buzz","external_id":"00000000-0000-4000-8000-000000000002","name":"Example reading journal colors","status":"active"}],
          "agents": [{"id":"agent_pm","display_name":"Demo Coordinator","role_label":"planner","status":"blocked","stage_links":[{"stage_key":"plan","link_role":"planner","link_state":"waiting"}]}],
          "pi_sessions": [],
          "stages": [
            {"id":"s1","stage_key":"start-ticket","state":"complete","attention":"none","checkpoint_state":"none","summary":"Idea promoted into the shared work route.","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s2","stage_key":"plan","state":"active","attention":"human","checkpoint_state":"pending","summary":"Interaction contract is ready for approval.","agents":[{"id":"agent_pm","display_name":"Demo Coordinator","role_label":"planner","status":"blocked","link_role":"planner"}],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s3","stage_key":"implement","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s4","stage_key":"architect-code-review","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s5","stage_key":"proof","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s6","stage_key":"code-review-pre-pr","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s7","stage_key":"pr","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]},
            {"id":"s8","stage_key":"pr-triage","state":"pending","attention":"none","checkpoint_state":"none","summary":"","agents":[],"pi_sessions":[],"buzz_threads":[]}
          ],
          "activity": []
        }
      ],
      "jira_candidates": [
        {"key":"DEMO-102","title":"Add labels to the fictional weather chart","status":"In Progress","priority":"Medium","issue_type":"Story","url":"https://example.atlassian.net/browse/DEMO-102","setup_state":"available"}
      ]
    }
    """#
}
