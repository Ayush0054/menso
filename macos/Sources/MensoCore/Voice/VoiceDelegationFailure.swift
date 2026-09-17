import Foundation

/// Fixed, actionable messages; never speak raw provider errors, request bodies,
/// tokens, or model output. A failed result is not proof an action did not run.
enum VoiceDelegationFailure {
    static func summary(for error: Error) -> String {
        switch error {
        case TypeSafeActionError.notConfigured:
            return "Mac actions need a TypeSafe API key on the Menso backend. Configure TYPESAFE_API_KEY, then restart the API."
        case TypeSafeActionError.unavailable:
            return "TypeSafe couldn't select an action. Check the backend connection and TypeSafe key, then try again."
        case AgentOSClientError.expiredAccessToken,
             AgentOSClientError.httpStatus(401), AgentOSClientError.httpStatus(403):
            return "The task connection needs authentication. Check your Menso connection in Settings."
        case AgentOSClientError.authenticatedIdentityMismatch:
            return "The task account no longer matches this conversation. End it and check Settings."
        case AgentOSClientError.httpStatus(404):
            return "The action endpoint wasn't found. Check the backend URL and update the Menso API."
        case AgentOSClientError.httpStatus(429):
            return "The task service is rate-limited. Wait a moment before trying again."
        case AgentOSClientError.invalidResponse, is DecodingError:
            return "Menso couldn't read the task result. Check the target app before trying again."
        case AgentOSRunStreamIngestorError.authorityUnavailable:
            return "I couldn't identify that Mac target. Name the app, or focus the field or control you mean, and ask again."
        case AgentOSRunStreamIngestorError.macControlPermissionRequired:
            return "Choose Enable Mac control in Menso and allow Accessibility in System Settings, then ask again."
        case AgentOSRunStreamIngestorError.unsupportedPause,
             AgentOSRunStreamIngestorError.ambiguousPause,
             ExternalActionRequestFactoryError.bindingMismatch:
            return "I couldn't match that to one supported action. Name the app or focus the intended field, then ask for one action at a time."
        case ExternalActionRequestFactoryError.expired:
            return "That action request expired. Ask again to create a fresh request."
        case AgentOSRunStreamIngestorError.malformedEvent:
            return "Menso couldn't read the task's action request. Check the backend before trying again."
        case AgentOSRunStreamIngestorError.unexpectedRun,
             AgentOSRunStreamIngestorError.authorityConflict:
            return "Menso couldn't match this result to your current request. Check the target app before retrying."
        case LiveVoiceError.invalidDelegation:
            return "Menso couldn't verify the task result. Check the target app before retrying; completion is not confirmed."
        case is CancellationError:
            return "The task was interrupted. Check the target app before trying again."
        case let networkError as URLError where networkError.code == .timedOut:
            return "The task connection timed out. Check the target app before trying again."
        case is URLError:
            return "The task connection was interrupted. Check the backend connection and target app before retrying."
        default:
            return "Menso couldn't confirm the task outcome. Check the target app and backend before retrying."
        }
    }
}
