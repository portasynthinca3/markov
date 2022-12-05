use Amnesia

defdatabase Markov.Database do
  deftable Master, [:model, :state], type: :set do
    @type t :: %Master{
      model: term(),                       # model name
      state: Markov.ModelServer.State.t(), # server state
    }
  end

  deftable Link, [:mod_from, :tag, :to, :occurrences], type: :bag, index: [:to, :tag] do
    @type t :: %Link{
      mod_from: {term(), [term()]},   # model name and link source ("from")
      tag: term(),                    # tag
      to: term(),                     # link target ("to")
      occurrences: non_neg_integer(), # weight
    }
  end

  deftable Operation, [:model, :type, :ts, :argument], type: :bag, index: [:type] do
    @type t :: %Operation{
      model: term(),                 # model name
      type: Markov.log_entry_type(), # entry type
      ts: non_neg_integer(),         # unix millis
      argument: term(),              # custom term
    }
  end
end
