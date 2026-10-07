defmodule FunWithFlags.UI.Utils do
  @moduledoc false

  alias FunWithFlags.{Flag, Gate}


  def get_flag_status(%Flag{gates: gates} = flag) do
    case boolean_gate_open?(flag) do
      {:ok, true} ->
        :fully_open
      _ ->
        if any_other_gate_open?(gates) do
          :half_open
        else
          :closed
        end
    end
  end

  def boolean_gate_open?(%Flag{gates: gates}) do
    case Enum.find(gates, &Gate.boolean?/1) do
      %Gate{type: :boolean, enabled: enabled} ->
        {:ok, enabled}
      nil ->
        :missing
    end
  end

  defp any_other_gate_open?(gates) do
    gates
    |> Enum.filter(fn(gate) -> !Gate.boolean?(gate) end)
    |> Enum.any?(fn(%Gate{enabled: enabled}) -> enabled end)
  end


  def sort_flags(flags) do
    Enum.sort_by(flags, & &1.name)
  end

  # Create new flags as disabled.
  #
  # Here we are converting a user-provided string to an atom, which is
  # potentially dangerous because atoms are not garbage collected.
  # Since we're going to persist it, however, the idea is that it's going
  # to be used anyway, and to be fair filling the persistent store with
  # unneeded data is a bigger concern.
  #
  def create_flag_with_name(name, opts \\ []) do
    name
    |> String.to_atom()
    |> FunWithFlags.disable(opts)
  end


  def get_flag(name) do
    if safe_flag_exists?(name) do
      FunWithFlags.SimpleStore.lookup(String.to_existing_atom(name)) # {:ok, flag}, or raise
    else
      {:error, "not found"}
    end
  end


  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(" "), do: true
  def blank?(string) when is_binary(string) do
    length = string |> String.trim |> String.length
    length == 0
  end


  def boolean_gate(%Flag{gates: gates}) do
    Enum.find(gates, &Gate.boolean?/1)
  end

  def actor_gates(%Flag{gates: gates}) do
    gates
    |> Enum.filter(&Gate.actor?/1)
    |> Enum.sort_by(&(&1.for))
  end

  def group_gates(%Flag{gates: gates}) do
    gates
    |> Enum.filter(&Gate.group?/1)
    |> Enum.sort_by(&(&1.for))
  end

  def percentage_gate(%Flag{gates: gates}) do
    Enum.find(gates, fn(g) ->
      Gate.percentage_of_time?(g) or Gate.percentage_of_actors?(g)
    end)
  end


  def parse_bool("true"), do: true
  def parse_bool("1"), do: true
  def parse_bool(1), do: true
  def parse_bool(true), do: true
  def parse_bool(_), do: false


  def validate_flag_name(conn, name) do
    if Regex.match?(~r/^\w+$/, name) do
      if safe_flag_exists?(name) do
        path = Path.join(conn.assigns[:namespace], "/flags/" <> name)
        {:fail, "A flag named '#{name}' <u><a href='#{path}' class='text-danger'>already exists</a></u>."}
      else
        :ok
      end
    else
      {:fail, "Invalid flag name, it must match <code>/^\w+$/</code>."}
    end
  end


  # We don't want to just convert any user provided string to an atom because
  # atoms are not garbage collected, and this could potentially leak memory
  # if some endpoint was abused and hammered with random non-existing flag names.
  #
  # Getting the list of the current flag names will reference and create all the
  # current atoms, and then `String.to_existing_atom/1` will simply raise an
  # error if the name doesn't match any existing atom. That implicitly proves
  # that there is no flag for that name
  #
  defp safe_flag_exists?(name) do
    try do
      {:ok, all} = FunWithFlags.all_flag_names()
      Enum.member?(all, String.to_existing_atom(name))
    rescue
      ArgumentError -> false
    end
  end


  def sanitize(name) do
    name
    |> String.trim()
  end

  def validate(name) do
    string = to_string(name)
    cond do
      blank?(string) ->
        {:fail, "can't be blank"}
      String.match?(string, ~r/\?/) ->
        {:fail, "includes invalid characters: '?'"}
      # Dot-segments: in a URL path, browsers resolve /flags/foo/actors/..
      # to /flags/foo, so the gate's Clear form would delete the whole flag.
      string in [".", ".."] ->
        {:fail, "can't be '.' or '..'"}
      true ->
        :ok
    end
  end


  def parse_and_validate_float(string) do
    if blank?(string) do
      {:fail, "can't be blank"}
    else
      case Float.parse(string) do
        {float, _} when float > 0 and float < 1 ->
          {:ok, float}
        {_float, _} ->
          {:fail, "is outside the '0.0 < x < 1.0' range"}
        :error ->
          {:fail, "is not a valid decimal number"}
      end
    end
  end


  # The panel's percentage form sends a percent (0 < x < 100) with
  # `percent_unit=percent`; FunWithFlags wants a fraction. Stricter than
  # `parse_and_validate_float/1`: plain decimal digits only (no sign, no
  # exponent, no trailing junk). The division by 100 moves the decimal point
  # in the string, so "42.1337" gives exactly the float that typing
  # "0.421337" gives (no 0.42133700000000004).
  #
  def parse_and_validate_percent(string) do
    trimmed = if is_binary(string), do: String.trim(string), else: ""

    cond do
      blank?(trimmed) ->
        {:fail, "can't be blank"}

      not Regex.match?(~r/^(\d+(\.\d*)?|\.\d+)$/, trimmed) ->
        {:fail, "is not a valid percentage (use digits, e.g. 25 or 2.5)"}

      # 100 or more (integer part longer than 2 digits once leading zeros are
      # stripped): out of range, and checked before converting, because a
      # huge integer part makes Float.parse return :error.
      integer_digits(trimmed) > 2 ->
        {:fail, "is outside the '0 < x < 100' range"}

      true ->
        case Float.parse(percent_string_to_fraction(trimmed)) do
          {value, ""} when value > 0 and value < 1 -> {:ok, value}
          _ -> {:fail, "is outside the '0 < x < 100' range"}
        end
    end
  end

  defp integer_digits(percent) do
    percent
    |> String.split(".", parts: 2)
    |> hd()
    |> String.trim_leading("0")
    |> String.length()
  end

  defp percent_string_to_fraction(percent) do
    [int, frac] =
      case String.split(percent, ".", parts: 2) do
        [int] -> [int, ""]
        [int, frac] -> [int, frac]
      end

    digits = int <> frac
    point = String.length(int) - 2
    {digits, point} = if point < 1, do: {String.duplicate("0", 1 - point) <> digits, 1}, else: {digits, point}
    {whole, decimals} = String.split_at(digits, point)
    decimals = if decimals == "", do: "0", else: decimals
    whole <> "." <> decimals
  end


  # If we have an unexpected value here it's because people
  # are messing around with the <input>s in the form. Just
  # use a default for unexpected values.
  #
  def parse_percentage_type(string) do
    case string do
      "time" -> :time
      "actors" -> :actors
      _ -> :time
    end
  end


  # Deal with floating point rounding errors without
  # losing precision.
  #
  # for example, to avoid these:
  #   0.421337 * 100 = 42.133700000000005
  #   0.123457 * 100 = 12.345699999999999
  #
  def as_percentage(float) when is_float(float) do
    percentage = float * 100

    if round(percentage) == percentage do
      # our job is done
      percentage
    else
      # let's assume that here `percentage` has lots
      # of decimal digits with a rounding error.
      #
      # We know that this will be `> 2`, because
      # if it was `<= 2` then it would have
      # short-circuited in the if.
      decimal_digits = _decimal_digits(float)
      Float.round(percentage, decimal_digits - 2)
    end
  end


  defp _decimal_digits(float) do
    float
    |> Float.to_string()
    |> String.split(".")
    |> List.last()
    |> String.length()
  end

end
