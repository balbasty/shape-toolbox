function ll = llCategoricalPushed(mu, f, c, varargin)
% FORMAT ll = llCategoricalPushed(mu, f, c, (type), ('loop', loop), ('par', par))
%
% ** Required **
% mu   - Template
% f    - Observed image pushed in the template space.
% c    - Pushed voxel count.
% ** Optional **
% type - Type of the provided template:
%        * 'proba': Probability space [default]
%        * 'log'  : Log-probability space
%        * 'null' : Null-projection of the log-probability space
% ** Keyword arguments **
% loop - Specify how to split data processing
%        ('slice' or 'none' [default])
% par  - If true, parallelise processing [default: false]
% ** Output **
% ll   - Log-likelihood of the Normal matching term

    % --- Parse inputs
    p = inputParser;
    p.FunctionName = 'llCategoricalPushed';
    p.addRequired('mu',   @checkarray);
    p.addRequired('f',    @checkarray);
    p.addRequired('c',    @checkarray);
    p.addOptional('type',    'proba', @(X) ischar(X) && any(strcmpi(X, {'log', 'proba', 'null'})) );
    p.addParameter('loop',   '',      @ischar);
    p.addParameter('par',    false,   @isscalar);
    p.addParameter('debug',  false,   @isscalar);
    p.parse(mu, f, c, varargin{:});
    type  = p.Results.type;
    par   = p.Results.par;
    loop  = p.Results.loop;
    
    if p.Results.debug, fprintf('* llCategoricalPushed\n'); end;
    
    % --- Optimise parallelisation and splitting schemes
    if ~strcmpi(type, 'proba') && strcmpi(loop, 'component')
        loop = '';
    end
    if ~strcmpi(type, 'proba')
        [par, loop] = autoParLoop(par, loop, isa(mu, 'file_array'), size(mu, 3), 1);
    else
        [par, loop] = autoParLoop(par, loop, isa(mu, 'file_array'), size(mu, 3), size(mu, 4));
    end
    
    % --- Read dimensions
    dim  = [size(mu) 1 1];
    dlat = dim(1:3);
    nc   = dim(4);
    if strcmpi(type, 'null')
        R = null(ones([1 nc+1]));
    end
    
    % --- Initialise
    ll = 0;
    
    % --- No loop
    if strcmpi(loop, 'none')
        if p.Results.debug, fprintf('   - No loop\n'); end;
        if strcmpi(type, 'proba')
            ll = ll + onMemoryProba(mu, f, c);
        elseif strcmpi(type, 'log')
            ll = ll + onMemoryLog(mu, f, c);
        elseif strcmpi(type, 'null')
            mu = single(numeric(mu));
            mu = reshape(reshape(mu, [], nc) * R', [dlat nc]);
            ll = ll + onMemoryLog(mu, f, c);
        else
            error('Unknown template type %s', type);
        end
        
    % --- Loop on components
    elseif strcmpi(loop, 'component')
        if p.Results.debug
            if par > 0
                fprintf('   - Parallelise on components\n'); 
            else
                fprintf('   - Serialise on components\n'); 
            end
        end
        if strcmpi(type, 'proba')
            parfor (k=1:nc, par)
                ll = ll + onMemoryProba(mu(:,:,:,k), f(:,:,:,k), c);
            end
        else
            error('Loop on components not supported with type %s', type);
        end
    
    % --- Loop on slices
    elseif strcmpi(loop, 'slice')
        if p.Results.debug
            if par > 0
                fprintf('   - Parallelise on slices\n'); 
            else
                fprintf('   - Serialise on slices\n'); 
            end
        end
        if strcmpi(type, 'proba')
            parfor (z=1:dlat(3), par)
                ll = ll + onMemoryProba(mu(:,:,z,:), f(:,:,z,:), c(:,:,z));
            end
        elseif strcmpi(type, 'log')
            parfor (z=1:dlat(3), par)
                ll = ll + onMemoryLog(mu(:,:,z,:), f(:,:,z,:), c(:,:,z));
            end
        elseif strcmpi(type, 'null')
            dlatz = [dlat(1:2) 1];
            parfor (z=1:dlat(3), par)
                muz = single(numeric(mu(:,:,z,:)));
                muz = reshape(reshape(muz, [], nc) * R', [dlatz nc]);
                ll = ll + onMemoryLog(muz, f(:,:,z,:), c(:,:,z));
            end
        else
            error('Unknown template type %s', type);
        end
        
    end
end

function ll = onMemoryProba(mu, f, c)
    mu    = single(numeric(mu));
    f     = single(numeric(f));
    c     = single(numeric(c));
    msk   = isfinite(f) & isfinite(mu);
    msk   = bsxfun(@and, msk, c);
    mu    = max(eps('single'), min(1 - eps('single'), mu));
    ll    = sumall(f(msk) .* log(mu(msk)));
end

function ll = onMemoryLog(a, f, c)
% NB: I removed the sum_k f_k because it shoud be equal to 1
    a     = single(numeric(a));
    f     = single(numeric(f));
    c     = single(numeric(c));
    msk   = isfinite(f) & isfinite(a);
    msk   = bsxfun(@and, msk, c > 0);
    ll    = sumall(sum(f(msk) .* a(msk), 4) - log(sum(exp(a(msk)), 4)));
end
