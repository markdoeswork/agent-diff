# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agent_diff/editor"

class EditorTest < Minitest::Test
  def setup
    @bin = Dir.mktmpdir("agent_diff_editor")
  end

  def teardown
    FileUtils.remove_entry(@bin)
  end

  # A PATH holding only the named fake executables.
  def path_with(*names)
    names.each do |n|
      File.write(File.join(@bin, n), "#!/bin/sh\n")
      File.chmod(0o755, File.join(@bin, n))
    end
    { "PATH" => @bin }
  end

  def cmd(env)
    AgentDiff::Editor.command("/p/a.rb", 12, env: env)
  end

  def test_vi_family_and_most_editors_take_plus_line
    assert_equal ["vim", "+12", "/p/a.rb"], cmd("EDITOR" => "vim")
    assert_equal ["nano", "+12", "/p/a.rb"], cmd("EDITOR" => "nano")
    assert_equal ["emacs", "-nw", "+12", "/p/a.rb"], cmd("EDITOR" => "emacs -nw")
  end

  def test_helix_and_micro_take_file_colon_line
    assert_equal ["hx", "/p/a.rb:12"], cmd("EDITOR" => "hx")
    assert_equal ["/usr/bin/micro", "/p/a.rb:12"], cmd("EDITOR" => "/usr/bin/micro")
  end

  def test_vscode_waits_and_uses_goto
    assert_equal ["code", "--wait", "-g", "/p/a.rb:12"], cmd("EDITOR" => "code")
    assert_equal ["code", "-w", "-g", "/p/a.rb:12"], cmd("EDITOR" => "code -w")
  end

  def test_precedence_is_agent_diff_editor_then_visual_then_editor
    env = { "AGENT_DIFF_EDITOR" => "hx", "VISUAL" => "vim", "EDITOR" => "nano" }
    assert_equal "hx", cmd(env).first
    assert_equal "vim", cmd(env.merge("AGENT_DIFF_EDITOR" => "")).first
  end

  def test_falls_back_to_whatever_is_installed
    assert_equal "nvim", cmd(path_with("vi", "nvim")).first
    FileUtils.rm(File.join(@bin, "nvim"))
    assert_equal "vi", cmd({ "PATH" => @bin }).first
  end

  def test_nil_when_there_is_no_editor_at_all
    assert_nil cmd({ "PATH" => @bin })
  end
end
