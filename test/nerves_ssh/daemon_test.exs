defmodule NervesSSH.DaemonTest do
  use ExUnit.Case, async: false

  @test_command 'ssh -i test/fixtures/nerves_ssh_rsa 127.0.0.1 -p 4022 :ok'

  test "can recover from sshd failure" do
    # Test we can send SSH command
    state = :sys.get_state(NervesSSH.Daemon)
    assert :os.cmd(@test_command) == ':ok'

    Process.exit(state.sshd, :kill)

    # Give time for sshd to be restarted
    :timer.sleep(10)

    # Test that we have recovered and still send SSH command
    new_state = :sys.get_state(NervesSSH.Daemon)
    assert :os.cmd(@test_command) == ':ok'

    assert state.sshd != new_state.sshd
  end
end
