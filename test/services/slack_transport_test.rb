require "test_helper"
require "socket"

class SlackTransportTest < ActiveSupport::TestCase
  setup do
    @settings = Munawaba::Configuration::ATTRIBUTES.to_h { |key| [key, Munawaba.config.public_send(key)] }
  end

  teardown { @settings.each { |key, value| Munawaba.config.public_send("#{key}=", value) } }

  test "webhook validator rejects SSRF suffix userinfo query fragment port controls and path tricks" do
    invalid = ["http://hooks.slack.com/services/T/B/S", "https://hooks.slack.com.evil.test/services/T/B/S",
               "https://evil.test@hooks.slack.com/services/T/B/S", "https://hooks.slack.com:444/services/T/B/S",
               "https://hooks.slack.com/services/T/B/S?token=x", "https://hooks.slack.com/services/T/B/S#x",
               "https://hooks.slack.com/services/T//S", "https://hooks.slack-gov.com/services/T/B/S",
               "https://hooks.slack.com/services/T/B/S\n", "https://hooks.slack.com/", "https://hooks.slack.com/services/T/B/%0a"]
    invalid.each { |url| refute Munawaba::Slack::WebhookValidator.valid?(url), "Unsafe URL was accepted" }
    assert Munawaba::Slack::WebhookValidator.valid?("https://hooks.slack.com/services/T/B/S")
    Munawaba.config.slack_allowed_hosts += ["hooks.slack-gov.com", "slack.example.org"]
    assert Munawaba::Slack::WebhookValidator.valid?("https://hooks.slack-gov.com/services/T/B/S")
    assert Munawaba::Slack::WebhookValidator.valid?("https://slack.example.org/incoming")
  end

  test "contexts reject unknown keys nulls numeric strings and inconsistent transitions" do
    valid = {
      "test" => { "schema_version" => 1 }, "advance_reminder" => { "schema_version" => 1 }, "shift_start" => { "schema_version" => 1 },
      "assignment_change" => { "schema_version" => 1, "transition_type" => "override_created", "previous_person_id" => 1, "new_person_id" => 2, "override_id" => 3 },
      "next_assignment_change" => { "schema_version" => 1, "previous_next_person_id" => 1, "new_next_person_id" => 2, "described_shift_id" => 3 }
    }
    valid.each do |kind, context|
      assert Munawaba::Notifications::Context::V1.valid?(kind: kind, context: context)
      context.each_key do |key|
        refute Munawaba::Notifications::Context::V1.valid?(kind: kind, context: context.except(key))
        refute Munawaba::Notifications::Context::V1.valid?(kind: kind, context: context.merge(key => nil))
      end
      refute Munawaba::Notifications::Context::V1.valid?(kind: kind, context: context.merge("url" => "secret"))
      refute Munawaba::Notifications::Context::V1.valid?(kind: kind, context: context.merge("schema_version" => "1"))
    end
    sample = valid["assignment_change"]
    refute Munawaba::Notifications::Context::V1.valid?(kind: "assignment_change",
                                                       context: sample.merge("previous_person_id" => "1"))
    refute Munawaba::Notifications::Context::V1.valid?(kind: "assignment_change",
                                                       context: sample.merge("new_person_id" => 1))
    refute Munawaba::Notifications::Context::V1.valid?(kind: "assignment_change",
                                                       context: sample.merge("ended_override_id" => 4))
  end

  test "escaping cannot create channel mentions and personal email is never rendered" do
    person = Munawaba::Person.new(name: "<!channel> & all", email: "private@example.org")
    assert_equal "&lt;!channel&gt; &amp; all", Munawaba::Slack::Renderer.person(person)
    person.slack_member_id = "UABC123"
    assert_equal "<@UABC123>", Munawaba::Slack::Renderer.person(person)
    person.slack_member_id = "UABC123><!channel>"
    refute_includes Munawaba::Slack::Renderer.person(person), "<@"
    assert_equal "&amp;&lt;&gt;", Munawaba::Slack::Renderer.escape("&<>")
  end

  test "an already expired absolute deadline opens no socket and is not an unknown outcome" do
    Net::HTTP.expects(:new).never
    outcome = Munawaba::Slack::Client.call(webhook: "https://hooks.slack.com/services/T/B/S", payload: { text: "test" },
                                           deadline: Munawaba::Slack::Client.monotonic - 1)
    assert_equal :retry, outcome.status
    assert_equal "network_timeout", outcome.error_code
    refute outcome.unknown
  end

  test "fresh direct session ignores proxy environment and disables internal retry" do
    variables = %w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy]
    original_env = variables.to_h { |key| [key, ENV[key]] }
    variables.each { |key| ENV[key] = "http://proxy-user:proxy-password@127.0.0.1:1" }
    client = Net::HTTP.new("hooks.slack.com", 443, nil)
    Net::HTTP.expects(:new).with("hooks.slack.com", 443, nil).returns(client)
    stub_request(:post, "https://hooks.slack.com/services/T/B/S").to_return(status: 200)
    result = Munawaba::Slack::Client.call(webhook: "https://hooks.slack.com/services/T/B/S", payload: { text: "test" },
                                          deadline: Munawaba::Slack::Client.monotonic + 2)
    assert_equal :delivered, result.status
    assert_equal 0, client.max_retries
    assert_nil client.proxy_address
    assert_equal OpenSSL::SSL::VERIFY_PEER, client.verify_mode
    assert_requested :post, "https://hooks.slack.com/services/T/B/S", times: 1 do |request|
      !request.headers.key?("Proxy-Authorization")
    end
  ensure
    original_env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "a real TLS trickle is cut off by one total deadline despite continuing response progress" do
    WebMock.disable!
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = factory.issuer_certificate = certificate
    certificate.add_extension(factory.create_extension("subjectAltName", "DNS:localhost"))
    certificate.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    tcp = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new
    context.cert, context.key = certificate, key
    server = OpenSSL::SSL::SSLServer.new(tcp, context)
    received = Queue.new
    thread = Thread.new do
      socket = server.accept
      headers = +""
      headers << socket.read(1) until headers.end_with?("\r\n\r\n")
      length = headers[/Content-Length: (\d+)/i, 1].to_i
      socket.read(length)
      received << true
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n")
      100.times do
        socket.write("x")
        sleep 0.02
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      # The client's deadline should close the socket while the server trickles.
    ensure
      socket&.close
    end
    client = Net::HTTP.new("localhost", tcp.addr[1], nil)
    store = OpenSSL::X509::Store.new
    store.add_cert(certificate)
    client.cert_store = store
    Net::HTTP.expects(:new).with("localhost", 443, nil).returns(client)
    Munawaba.config.slack_allowed_hosts = ["localhost"]
    started = Munawaba::Slack::Client.monotonic
    result = Munawaba::Slack::Client.call(webhook: "https://localhost/incoming", payload: { text: "trickle test" },
                                          deadline: started + 0.3)
    elapsed = Munawaba::Slack::Client.monotonic - started
    assert_operator elapsed, :<, 0.8
    assert_operator received.size, :>, 0
    assert_equal :retry, result.status
    assert result.unknown
    assert_equal "delivery_outcome_unknown", result.error_code
    refute client.started?
  ensure
    tcp&.close
    thread&.kill
    thread&.join(1)
    WebMock.enable!
  end
end
