use Amnesia

defdatabase Markov.Database do
  deftable Master, [:model, :state], type: :set do
    @type t :: %Master{
      model: term(),                       # model name
      state: Markov.ModelServer.State.t(), # server state
    }
  end

  deftable Link, [:mod_from, :tag, :to], type: :bag do
    @type t :: %Link{
      mod_from: {term(), [term()]},   # model name and link source ("from")
      tag: term(),                    # tag
      to: term(),                     # link target ("to")
    }
  end

  deftable Weight, [:link, :value], type: :set do
    @type t :: %Weight{link: Link.t(), value: non_neg_integer()}
  end

  deftable Operation, [:model, :type, :ts, :argument], type: :bag do
    @type t :: %Operation{
      model: term(),                 # model name
      type: Markov.log_entry_type(), # entry type
      ts: non_neg_integer(),         # unix millis
      argument: term(),              # custom term
    }
  end
end
