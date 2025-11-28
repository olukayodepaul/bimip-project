defmodule Until.UniPosTime do

  def uni_pos_time do
    DateTime.utc_now()
    |> DateTime.to_unix(:millisecond)
  end

end
