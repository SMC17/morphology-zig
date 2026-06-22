defmodule MorphEnv.Nif do
  @on_load :load_nif

  def load_nif do
    # zig build outputs to zig-out/lib/libnif.so
    nif_file = ~c"./zig-out/lib/libnif"
    :erlang.load_nif(nif_file, 0)
  end

  def init_env(), do: :erlang.nif_error(:nif_not_loaded)
  def reset(_word), do: :erlang.nif_error(:nif_not_loaded)
  def step(_action), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule MorphEnv.Agent do
  require Logger

  def run_episode(word) do
    Logger.info("Starting episode for word: #{word}")
    
    # Initialize env
    :ok = MorphEnv.Nif.reset(word)
    
    # A random agent that just splits randomly
    loop_step(word, 0)
  end

  defp loop_step(word, step_count) do
    # Random action: 0 (no split) or 1 (split)
    action = Enum.random([0, 1])
    
    # Step the environment
    case MorphEnv.Nif.step(action) do
      {:ok, reward, true} ->
        Logger.info("Episode finished. Reward: #{reward}, Steps: #{step_count + 1}")
        reward
      {:ok, _reward, false} ->
        loop_step(word, step_count + 1)
      other ->
        Logger.error("Unexpected step result: #{inspect(other)}")
        0.0
    end
  end
end
