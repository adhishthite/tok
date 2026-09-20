import Foundation
import XCTest

@testable import TokEngine

/// Request encoding and response decoding for all three TypeSafe primitives (noul, choice,
/// score), from JSON fixtures shaped like docs/api.md and the confirmed live contract.
final class JudgmentEncodingTests: XCTestCase {

  // MARK: - Request encoding

  func testRequestEncodesNoulChoiceScoreQuestions() throws {
    let request = JudgmentRequest(
      model: "jev-latest",
      state: .object([
        "pairs": .array([.object(["wrong": .string("cloud"), "right": .string("Claude")])])
      ]),
      questions: [
        "genuine": .noul(
          instructions: "Is this genuine?",
          criteria: ["true": "yes example", "false": "no example"]),
        "register": .choice(
          instructions: "Pick a register.", criteria: ["chat": "casual", "prose": "formal"]),
        "risk": .score(
          instructions: "How risky?",
          criteria: ["would corrupt", "risky", "mostly safe", "safe"]),
      ])
    let data = try JSONEncoder().encode(request)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "jev-latest")
    let state = try XCTUnwrap(json["state"] as? [String: Any])
    let pairs = try XCTUnwrap(state["pairs"] as? [[String: Any]])
    XCTAssertEqual(pairs.first?["wrong"] as? String, "cloud")
    XCTAssertEqual(pairs.first?["right"] as? String, "Claude")

    let questions = try XCTUnwrap(json["questions"] as? [String: Any])
    let genuine = try XCTUnwrap(questions["genuine"] as? [String: Any])
    XCTAssertEqual(genuine["type"] as? String, "noul")
    XCTAssertEqual(genuine["instructions"] as? String, "Is this genuine?")
    let genuineCriteria = try XCTUnwrap(genuine["criteria"] as? [String: String])
    XCTAssertEqual(genuineCriteria["true"], "yes example")

    let register = try XCTUnwrap(questions["register"] as? [String: Any])
    XCTAssertEqual(register["type"] as? String, "choice")
    let registerCriteria = try XCTUnwrap(register["criteria"] as? [String: String])
    XCTAssertEqual(registerCriteria["chat"], "casual")

    let risk = try XCTUnwrap(questions["risk"] as? [String: Any])
    XCTAssertEqual(risk["type"] as? String, "score")
    let riskCriteria = try XCTUnwrap(risk["criteria"] as? [String])
    XCTAssertEqual(riskCriteria, ["would corrupt", "risky", "mostly safe", "safe"])
  }

  func testNoulQuestionOmitsCriteriaWhenNil() throws {
    let data = try JSONEncoder().encode(
      ["q": JudgmentQuestion.noul(instructions: "Is it true?")])
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let q = try XCTUnwrap(json["q"] as? [String: Any])
    XCTAssertNil(q["criteria"])
  }

  // MARK: - Response decoding

  func testDecodesNoulChoiceScoreAnswersAndUsage() throws {
    let json = """
      {
        "model": "jev-1.13.0",
        "answers": {
          "genuine": {"type": "noul", "noul": 0.73},
          "register": {"type": "choice", "choice": "chat", "probabilities": {"chat": 0.9, "prose": 0.1}, "confidence": 0.82},
          "risk": {"type": "score", "score": 2.51, "legend": {"0": "would corrupt", "1": "risky", "2": "mostly safe", "3": "safe"}, "probabilities": {"0": 0.0, "1": 0.01, "2": 0.47, "3": 0.52}, "confidence": 0.51}
        },
        "usage": {"input_tokens": 335, "output_tokens": 21}
      }
      """
    let response = try JSONDecoder().decode(JudgmentResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.model, "jev-1.13.0")
    XCTAssertEqual(response.usage.inputTokens, 335)
    XCTAssertEqual(response.usage.outputTokens, 21)

    guard case .noul(let value)? = response.answers["genuine"] else {
      return XCTFail("expected a noul answer")
    }
    XCTAssertEqual(value, 0.73, accuracy: 0.0001)

    guard case .choice(let choice, let confidence)? = response.answers["register"] else {
      return XCTFail("expected a choice answer")
    }
    XCTAssertEqual(choice, "chat")
    XCTAssertEqual(confidence ?? -1, 0.82, accuracy: 0.0001)

    // Live contract (verified 2026-09-21): `score` is 0-indexed over the level list, so a
    // 4-level question answers in 0...3 as the probability-weighted mean of level positions.
    guard case .score(let score, let scoreConfidence)? = response.answers["risk"] else {
      return XCTFail("expected a score answer")
    }
    XCTAssertEqual(score, 2.51, accuracy: 0.0001)
    XCTAssertEqual(scoreConfidence ?? -1, 0.51, accuracy: 0.0001)
  }

  func testUnknownAnswerTypeDecodesAsUnknownRatherThanThrowing() throws {
    let json = """
      {"model": "jev-1.13.0", "answers": {"x": {"type": "mystery"}}, "usage": {}}
      """
    let response = try JSONDecoder().decode(JudgmentResponse.self, from: Data(json.utf8))
    guard case .unknown? = response.answers["x"] else { return XCTFail("expected .unknown") }
    XCTAssertNil(response.usage.inputTokens)
    XCTAssertNil(response.usage.outputTokens)
  }
}
