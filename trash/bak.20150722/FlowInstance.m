classdef FlowInstance < handle
    % A flow instance, which is offseted perodic iid traffic
    % Note that it could be overlapped 
    
    properties (SetAccess = public, GetAccess = public)
        
        % the offset of the first packet of the flow
        % Dimension: zeros(1,1)
        offset;
        
        % the period of the flow
        % Dimension: zeros(1,1)
        period;
        
        % the delay of each flow, delay(ii) <= period (ii) because we only consider non-overlapping traffic
        % Dimension:zeros(1,1)
        delay;
        
        % the Bernoulli arrival probability in one period
        %Dimension: zeros(period,1);
        arrival_prob;
        
        % the probability to successfully deliver a packet of each flow if scheduled
        % Dimension: zeros(1,1)
        success_prob;
        
        
        % number of states, in terms of lead time,
        % state is from 1 to 2^delay, which represents from (00...0) to (11...1)
        % that is to say state i is the binary representation of decimal integer i-1
        % we use the left most bit to reprensent lead time 1 and the right
        % most bit to repensent lead time delay
        
        % For example: delay =2  ('_b' means base 2, '_d' means base 10)
        % state 1 = (00)_b = (0)_d,  lead time 1 no; lead time 2 no;   de2bi(1-1,2,'left-msb')=[0 0], bi2de([0 0], 'left-msb')+1=1
        % state 2 = (01)_b = (1)_d,  lead time 1 no; lead time 2 yes;  de2bi(2-1,2,'left-msb')=[0 1], bi2de([0 1], 'left-msb')+1=2
        % state 3 = (10)_b = (2)_d,  lead time 1 yes; lead time 2 no;  de2bi(3-1,2,'left-msb')=[1 0], bi2de([1 0], 'left-msb')+1=3
        % state 4 = (11)_b = (3)_d,  lead time 1 yes; lead time 2 yes; de2bi(4-1,2,'left-msb')=[1 1], bi2de([1 1], 'left-msb')+1=4
        n_state;
        
        % number of actions
        % action 1: transmit this flow
        % action 2: do not transmit this flow
        n_action = 2;

        % transition probability only due to transmission and expiration, since TX&E is
        % idependent of time, i.e., transmition_matrix_txe is the same for
        % all slots, we will ignore the time dimension here.
        % Dimension:  zeros(n_state, n_action, n_state);
        % transmition_matrix_txe(i, a, j) is the probability from state i under action a at the beginnong of any slot t
        % to the state j at the end of the slot t if we only consider
        % transmission and expiration but ignore arrival
        transition_matrix_txe;
        
        
        % transition probability only due to arrival
        % Note that this only happens at the END of each slot, i.e., after TX transition probability
        % Since A is periodic with period period, we will only
        % consider the first period, i.e., from slot 1 to slot period.
        % For any time slot t, note that transition_matrix_a(t, i, j) = transition_matrix_a(rem(t, period), i, j)
        % Dimension: zeros(period, n_state, n_state);
        % transition_matrix_a(t, i, j) is the probability from state i at the end of slot t to
        % state j at the beginning of slot t+1 if we only consider A but ignore transimission and expiration. 
        % The arrival is random accoding to the arrival_prob.
        transition_matrix_a;
        
        % transition probability due to both transmission and A&E (first TX
        % from the beginning of each slot to the end of the slot, then AE
        % from the end of the slot to the begnning of next slot)
        % Since TX is independnt of slots (or periodic with period 1) and A&E is periodic with period period, we will only
        % consider the first period, i.e., from slot 1 to slot period. (BUT
        % remember here we ignore the offset! So it is actuall from slot offset+1 to offset+period)
        % For any time slot t, note that transition_matrix(t, i, a, j) = transition_matrix(rem(t, period), i, a, j)
        % Dimension:  zeros(period, n_state, n_action, n_state)
        % transmition_matrix(t, i, a, j) is the probability from state i under action a at the beginning of slot t
        % to the state j at the begnning of slot t+1 if we consider both transmission and A&E
        transition_matrix;
        
        % the reward per slot for each state-action
        % Dimension: zeros(n_state, n_action)
        reward_per_state_per_action;
    end
    
    methods
        
        function  obj=FlowInstance()
            %constructor function
        end
        
        
        %judge whether the input parameters are valid
        function [ret] = isValid(obj)
            ret = 1;
            if(obj.period <= 0 || obj.delay <= 0 || ...
                   obj.success_prob <=0 || obj.success_prob >=1 || length(obj.arrival_prob) ~= obj.period)
                ret = -1;
                error('wrong input');
            end
        end
        
        
        %calculate some other parameters according to the input parameters
        function calculateParameters(obj)
            obj.n_state = 2^obj.delay;
            obj.n_action = 2;
        end
        
        function constructEverything(obj)
            if(isValid(obj) == -1)
                return;
            end
            
            calculateParameters(obj);
            constructTransitionMatrixTXE(obj);
            constructTransitionMatrixA(obj);
            constructTransitionMatrix(obj);
            constructRewardPerStatePerAction(obj);
        end
        
        %convert state into binary representation
        function [state_bin] = getBinaryState(obj, state)
            if(state < 1 || state > obj.n_state)
                error('wrong input');
            end
            state_bin = de2bi(state-1, obj.delay, 'left-msb');
        end
        
        %convert binary representation into state
        function [state] = getStateFromBinary(obj, state_bin)
            if(length(state_bin) ~= obj.delay)
                error('wrong input');
            end
            state = bi2de(state_bin, 'left-msb')+1;
        end
        
        %judge if the flow has one packet at the input state
        function [ret] = hasPacket(obj, state)
            if(state > 1)
                ret = 1;
            else
                ret = 0;
            end
        end
        
        
        function [slot] = getFirstPeriodSlot(obj, t)
            if( t <= obj.offset) %we do not consider the slots before offset
                error('wrong input');
            end
            slot = rem(t-obj.offset, obj.period);
            
            %if t = k * obj.period, then the reminder is 0 and we
            %should map it to slot obj.period
            if(slot == 0)
                slot = obj.period;
            end
        end
        
        %find the packet with least lead time under the input state
        function [least_lead_time] = findLeastLeadTimePacket(obj, state)
            if(state < 0 || state > obj.n_state)
                error('wrong input');
            end
            state_bin = obj.getBinaryState(state);
            least_lead_time = 0;
            for ii=1:obj.delay
                if(state_bin(ii) == 1)
                    least_lead_time = ii;
                    break;
                end
            end
        end
        
      
        
        %construct the transition matrix due to TX and expiration
        function constructTransitionMatrixTXE(obj)   
            %transmition_matrix_tx(i,a,j) is the probability from state i under action a at the beginning of any slot t
            %to the state j at the end slot t if we only consider
            %transmission and expiration but ignore arrival
            obj.transition_matrix_txe = zeros(obj.n_state, obj.n_action, obj.n_state);
            
            % if the state is 1 (no packet), then with probability 1 to go
            % to state 1 again
            obj.transition_matrix_txe(1,:,1) = 1;
            
            for ss=2:obj.n_state
                least_lead_time = obj.findLeastLeadTimePacket(ss);
                ss_bin = obj.getBinaryState(ss);
                
                %first shift the lead time, 
                ss_shift_bin = zeros(1,obj.delay);
                for ii=1:obj.delay-1
                    ss_shift_bin(ii) = ss_bin(ii+1);
                end
                
                
                %then consider transmission
                
                %action 2 is not to transmit this flow
                ss_shift = obj.getStateFromBinary(ss_shift_bin);
                obj.transition_matrix_txe(ss, 2, ss_shift) = 1;
                
                %action 1 is to transmit this flow
                if(least_lead_time == 1) %transmit the packet with lead time 1, which will be expired
                    obj.transition_matrix_txe(ss, 1, ss_shift) = 1;
                else
                    %sanity check
                    if( ss_shift_bin(least_lead_time-1) ~= 1)
                        error('something wrong');
                    end
                    
                    %the prob. of successful transmission
                    ss_shift_success_bin = ss_shift_bin;
                    ss_shift_success_bin(least_lead_time-1) = 0;
                    ss_shift_success = obj.getStateFromBinary( ss_shift_success_bin);
                    obj.transition_matrix_txe(ss, 1,  ss_shift_success) = obj.success_prob;
                    %the prob. of failed transmission
                    obj.transition_matrix_txe(ss, 1,  ss_shift) = 1 - obj.success_prob;      
                end
            end
            
            %sanity check
            for ss=1:obj.n_state
                for aa=1:obj.n_action
                    if(abs(sum(obj.transition_matrix_txe(ss,aa,:)) - 1) > 1e-6)
                        dist = abs(sum(obj.transition_matrix_txe(ss,aa,:)) - 1)
                        error('wrong probability for state %d action %d', ss, aa);
                    end
                end
            end
        end
        
        %construct the transition matrix due to arrival
        function constructTransitionMatrixA(obj) 
            %transition_matrix_a is the transition probability only due to arrival
            obj.transition_matrix_a = zeros(obj.period, obj.n_state, obj.n_state);
            for tt=1:obj.period
                for ss=1:obj.n_state
                    ss_bin = obj.getBinaryState(ss);
                    if(ss_bin(end) == 1)
                        obj.transition_matrix_a(tt, ss, ss) = 1;
                    else %no packet with lead time = delay
                        %consider arrival (A)
                        next_state_noarrival_bin = ss_bin;
                        next_state_arrival_bin = ss_bin;
                        next_state_arrival_bin(obj.delay) = 1;
                        next_state_noarrival = obj.getStateFromBinary(next_state_noarrival_bin);
                        next_state_arrival = obj.getStateFromBinary(next_state_arrival_bin);
                        obj.transition_matrix_a(tt, ss, next_state_noarrival) = 1-obj.arrival_prob(tt);
                        obj.transition_matrix_a(tt, ss, next_state_arrival) = obj.arrival_prob(tt);
                    end
                end
            end
            
            %sanity check
            for tt=1:obj.period
                for ss=1:obj.n_state
                    if(abs(sum(obj.transition_matrix_a(tt,ss,:)) - 1) > 1e-6)
                        dist = abs(sum(obj.transition_matrix_a(tt,ss,:)) - 1)
                        error('wrong probability for time %d state %d', tt, ss);
                    end
                end
            end
        end
        
        %construct the transition matrix by considering both TXE and A
        function constructTransitionMatrix(obj)
            %transition probability due to both transmission and A&E
            obj.transition_matrix = zeros(obj.period, obj.n_state, obj.n_action, obj.n_state);
            for tt=1:obj.period
                for ss=1:obj.n_state
                    for aa=1:obj.n_action
                        for next_state=1:obj.n_state
                            tran_prob_temp = 0;
                            for txe_state=1:obj.n_state
                                tran_prob_temp = tran_prob_temp + (obj.transition_matrix_txe(ss,aa,txe_state))*(obj.transition_matrix_a(tt,txe_state,next_state));
                            end
                            obj.transition_matrix(tt,ss, aa, next_state) = tran_prob_temp;
                        end
                    end
                end
            end
            
            %sanity check
            for tt=1:obj.period
                for ss=1:obj.n_state
                    for aa=1:obj.n_action
                        if(abs(sum(obj.transition_matrix(tt,ss,aa,:)) - 1) > 1e-6)
                            dist = abs(sum(obj.transition_matrix(tt,ss,:)) - 1)
                            error('wrong probability for tt %d state %d action %d', tt, ss, aa);
                        end
                    end
                end
            end
        end
        
        %construct the reward per reward per state. Equation 11 in Mobihoc 2015
        % Note that this reward is not related to any coefficient or the
        % period. To use them, we need to normalized by coefficient if weighted-sum utility is considered.
        function constructRewardPerStatePerAction(obj)   
            obj.reward_per_state_per_action = zeros(obj.n_state, obj.n_action);
            %state 1, no packets
            obj.reward_per_state_per_action(1,:) = 0;
            %state > 1, action 1 is to transmit this flow
            obj.reward_per_state_per_action(2:end,1) = obj.success_prob;
            %state > 1, action 2 is not to transmit this flow
            obj.reward_per_state_per_action(2:end,2) = 0;
        end
        
        function [prob] = getTransitionProbability(obj, t, state, action, next_state)
            if(t <=0 || state <=0 || state > obj.n_state || action <=0 || action > obj.n_action ...
                    || next_state <=0 || next_state > obj.n_state)
                error('wrong input');
            end
            if( t <= obj.offset)
                if(next_state == 1) %it comes to state 1 no matter what state and what action is
                    prob = 1;
                else
                    prob = 0;
                end
            else %% t > obj.offset
                prob = obj.transition_matrix(obj.getFirstPeriodSlot(t), state, action, next_state);
            end
            
        end
       
    end

end