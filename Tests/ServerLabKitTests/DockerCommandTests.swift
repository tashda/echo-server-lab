import Testing
@testable import ServerLabKit

struct DockerCommandTests {
    @Test(arguments: [
        "error during connect: Get \"http://docker.example.com/v1.47/containers/json\": command [ssh -- testlab docker system dial-stdio] has exited with exit status 255",
        "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
        "read: connection reset by peer (command [ssh -- testlab docker system dial-stdio])",
    ])
    func retriesWhenTheHostWasNotReached(_ message: String) {
        #expect(DockerCommand.couldNotConnect(message))
    }

    @Test(arguments: [
        "Error response from daemon: No such container: serverlab-x",
        "Error response from daemon: Conflict. The container name \"/serverlab-x\" is already in use",
        "",
    ])
    func doesNotRetryWhatTheDaemonRefused(_ message: String) {
        #expect(!DockerCommand.couldNotConnect(message))
    }
}
