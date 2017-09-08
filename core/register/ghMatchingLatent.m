function [g, h] = ghMatchingLatent(model, mu, f, c, gmu, w, varargin)
% FORMAT [g, h] = obj.ghMatchingLatent(model, mu, f, c, gmu, w)
%
% ** Required **
% model - 'normal', 'laplace', 'bernoulli', 'categorical'
% mu    - (Reconstructed) template image ([nx ny nz nc])
% f     - Observed image pushed into template space ([nx ny nz nc])
% c     - Pushed voxel count ([nx ny nz nc])
% gmu   - Template spatial gradients.
% w     - Principal subspace
% ** Keyword arguments **
% sigma2- Noise variance for the normal case [default: 1]
% b     - Noise variance for the laplace case [default: 1]
% loop  - How to split: 'none', 'slice' [default: auto]
% par   - Parallelise: false/true/number of workers [default: auto]
% approx- Approximate hessian [default: true]
% ** Outputs **
% g     - First derivatives w.r.t. latent PC parameters ([nq])
% h     - Second derivatives w.r.t. latent PC parameters ([nq nq])
%
% Compute gradient/hessian with respect to latent parameters in the
% principal subspace.

    % --- Parse inputs
    p = inputParser;
    p.FunctionName = 'ghMatchingLatent';
    p.addRequired('model',  @ischar);
    p.addRequired('mu',     @checkarray);
    p.addRequired('f',      @checkarray);
    p.addRequired('c',      @checkarray);
    p.addRequired('gmu',    @checkarray);
    p.addRequired('w',      @checkarray);
    p.addParameter('sigma2',   1,       @isscalar);
    p.addParameter('b',        1,       @isscalar);
    p.addParameter('loop',     '',      @ischar);
    p.addParameter('par',      true,    @isscalar);
    p.addParameter('output',   []);
    p.addParameter('debug',    false,   @isscalar);
    p.parse(model, mu, f, c, gmu, w, varargin{:});
    s       = p.Results.sigma2;
    b       = p.Results.b;
    loop    = p.Results.loop;
    par     = p.Results.par;
    output  = p.Results.output;
    debug   = p.Results.debug;
    
    if p.Results.debug, fprintf('* ghMatchingLatent\n'); end;
    
    % --- Optimise parallelisation and splitting schemes
    [par, loop] = autoParLoop(par, loop, isa(w, 'file_array'), size(w,3));
    
    % --- Allocate arrays for grad and hessian
    nk  = size(w,5);
    g = zeros([nk 1], 'double');
    do_hessian = nargout > 1;
    if do_hessian
        h = zeros(nk, 'double');
    end

    % --- If loop on slices
    if strcmpi(loop, 'slice')
        if debug
            if par
                fprintf('  - Parallelise on slices\n')
            else
                fprintf('  - Serialise on slices\n')
            end
        end
        if do_hessian
            parfor (z=1:dim_lattice(3), par)
                [g1, h1] = onMemory(model, ...
                    mu(:,:,z,:), f(:,:,z,:), c(:,:,z), ...
                    gmu(:,:,z,:,:), w(:,:,z,:,:), ...
                    'sigma2',   s, ...
                    'b',        b, ...
                    'loop',     'none', ...
                    'par',      false);
                g = g + g1;
                h = h + h1;
            end
        else
            parfor (z=1:dim_lattice(3), par)
                g1 = onMemory(model, ...
                    mu(:,:,z,:), f(:,:,z,:), c(:,:,z), ...
                    gmu(:,:,z,:,:), w(:,:,z,:,:), ...
                    'sigma2',   s, ...
                    'b',        b, ...
                    'loop',     'none', ...
                    'par',      false);
                g = g + g1;
            end
        end 
    % --- No loop
    else
        if debug
            fprintf('  - No loop\n')
        end
        if do_hessian
            [g, h] = onMemory(model, mu, f, c, gmu, w, ...
                'sigma2',   s, ...
                'b',        b, ...
                'loop',     loop, ...
                'par',      par, ...
                'debug',    debug);
        else
            g = onMemory(model, mu, f, c, gmu, w, ...
                'sigma2',   s, ...
                'b',        b, ...
                'loop',     loop, ...
                'par',      par, ...
                'debug',    debug);
        end
    end

    % Insure symmetric hessian
    h = (h + h')/2;
    
    % Just in case
    g(~isfinite(g)) = 0;
    h(~isfinite(h)) = 0;
    
    % --- Write on disk    
    if ~iscell(output)
        output = {output};
    end
    if numel(output) < 2
        output = [output {[]}];
    end
    if ~isempty(output{1})
        g = saveOnDisk(g, output{1}, 'name', 'g');
    end
    if nargout > 1 && ~isempty(output{2})
        h = saveOnDisk(h, output{2}, 'name', 'h');
    end
end

function [g, h] = onMemory(model, mu, f, c, gmu, w, varargin)


    % --- Multiply PCs with template gradients
    w = -pointwise(single(numeric(gmu)), single(numeric(w)));
    clear gmu
    % => size(w) = [nx ny nz nclasses nlatent]

    % --- Compute grad/hess w.r.t. the complete velocity
    % (fast version that does not perform grad multiplication)
    if nargout > 1
        [g, h, htype] = ghMatchingVel(model, mu, f, c, varargin{:});
    else
        g = gradHessMatchingVel(model, mu, f, c, varargin{:});
    end
    clear mu f c

    % --- Compute grad/hess w.r.t. the latent (low-dim) coordinates
    if nargout > 1
        [g, h] = vel2latGradHessMatching(w, g, h, htype);
    else
        g = vel2latGradHessMatching(w, g);
    end
    clear w
end
    
function [g, h] = vel2latGradHessMatching(w, g, h1, htype)
% FORMAT [g, h] = vel2latGradHessMatching(w, g, h, htype)
% w     - Shape subspace basis (pre-multiplied by the template gradients)
% g     - Gradient w.r.t. the full velocity
% h     - Hessian w.r.t. the full velocity
% htype - Type of the hessian approximation w.r.t. classes:
%         'diagonal' or 'symtensor'
%
% Apply the chain rule to convert Grad/Hess w.r.t. the full velocity to
% Grad/Hes w.r.t. the latent coordinates.

    % --- Dim info
    dim         = [size(w) 1 1 1];
    dim         = dim(1:5);
    dim_lattice = dim(1:3);
    dim_classes = dim(4);   % Number of classes (Pre-multiplied W(xi,k) * -Gmu(xi))
    dim_latent  = dim(5);
    
    % --- Default arguments
    do_hessian = (nargout > 1) && (nargin > 2);
    if do_hessian && nargin < 4
        % Try to guess htype
        if issame(size(h1), size(g))
            htype = 'diagonal';
        else
            htype = 'symtensor';
        end
    end
    
    % --- Gradient
    % G = w' * g1
    w = reshape(w, [], dim_latent); % Matrix form
    g = double(w' * g(:));
    
    % --- Hessian
    if do_hessian
        h = zeros(size(g, 1), 'double');
        switch htype
            case {'symtensor'}
                % H = sum_{j,k} [ w_j' * h1_{j,k} * w_k ]
                % ^ where j, k are classes/modalities
                ind = symIndices(size(h1, 4));
                w = reshape(w, [prod(dim_lattice) dim_classes dim_latent]);
                for j=1:dim_classes
                    for k=1:dim_classes
                        wk = reshape(w(:,k,:), [], dim_latent);
                        hjk = h1(:,:,:,ind(j, k));
                        % > h1_{j,k} * w_k
                        hjk = bsxfun(@times, hjk(:), wk);
                        clear wk
                        wj = reshape(w(:,j,:), [], dim_latent);
                        % > w_j' * h1_{j,k} * w_ka
                        h = h + double(wj' * hjk);
                        clear hjk wj
                    end
                end
            case {'diagonal'}
                % H = sum_k [ w_k' * h1_k * w_k ]
                % ^ where k is a class/modality
                w = reshape(w, [prod(dim_lattice) dim_classes dim_latent]);
                for k=1:dim_classes
                    wk = reshape(w(:,k,:), [], dim_latent);
                    hk = h1(:,:,:,k);
                    h = h + double(wk' * bsxfun(@times, hk(:), wk));
                    clear wk hk
                end
            otherwise
                error('Unknown hessian type.');
        end
    end
    
end
