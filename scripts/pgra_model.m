function [model, dat] = pgra_model(opt, dat, model, cont)
% _________________________________________________________________________
%
% FORMAT [model, dat, opt] = pgra_model(opt, (dat), (model))
%
% Optimises a "principal geodesic" model on a collection of images.
%
% The input option structure (opt) should at least contain the field:
% fnames.f - observed images (as a list of filenames)
%
% Alternatively, an input data structure array (dat), of size the number
% of images, can be provided with at least the field:
% f        - observed images (as a list of array or file_array)
%
% The following parameters can be overriden by specifying them in the
% input option (opt) structure:
% model        - Generative model [struct('name', 'normal', 'sigma2', 1)]
% K            - Number of principal geodesics [32]
% lat          - Template lattice dimensions [auto]
% vs           - Template lattice voxel size [auto]
% Mf           - Force same voxel-to-world to all images [read from file]
% itrp         - Interpolation order [1]
% bnd          - Boundary conditions [1]
% emit         - Number of EM iterations [100]
% gnit         - Number of GN iterations for latent variables update [2]
% lsit         - Number of line search iterations [6]
% itgr         - Number of integration steps for geodesic shooting [auto]
% prm          - Parameters of the geodesic differential operator
%                [1e-4 1e-3 0.2 0.05 0.2]
% wpz          - Weights on both parts (A and W'LW) of the prior on z [1 1]
% wpz0         - Initial weights for more robustness [1 5]
% nz0          - Number of DF of the latent Wishart prior [K]
% nq0          - Number of DF of the affine Wishart prior [size(affine_basis,3)]
% lambda0      - Initial residual expected precision [10]
% nlambda0     - Initial residual Gamma DF (~nb of subjects) [10]
% affine_basis - Generated by the affine_basis function [affine_basis(12)]
% affine_rind  - Indices of regularised affine params [affine_basis(12)]
% happrox      - Approximate affine hessian [true]
% fwhm         - Smoothing kernel used as template pseudo-prior (mm) [3]
% verbose      - Talk during line search [true]
% debug        - Further debuging talk [false]
% loop         - How to split array processing 'subject', 'slice' or 'none'
%                ['subject']
% par          - Parallelise processing 0/n/inf [inf]
% batch        - Batch size for parallelisation [auto].
% directory    - Directory where to store result arrays ['.']
% fnames.result- Filename for the result environment saved after each EM
%                iteration ['pg_result.mat']
% fnames.model - Structure of filenames for all temporary arrays
%                (mu, gmu, (a), w, dw, g, h)
% fnames.dat   - Structure of filenames for all temporary arrays
%                (f, v, ipsi, iphi, pf, c, wmu, r)
% ondisk.model - Structure of logical for temporary array [default_ondisk]
% ondisk.dat   - "      "       "       "       "       "
% _________________________________________________________________________
%
% FORMAT [model, dat, opt] = pgra_model(opt, dat, model, 'continue')
%
% The returned structures (or the saved environment which also contains
% them) can be used as input to start optimising from a previous state.
% _________________________________________________________________________

    % ---------------------------------------------------------------------
    %    Default parameters
    % ---------------------------------------------------------------------
    if nargin < 4
        cont = '';
        if nargin < 3
            model = struct;
            if nargin < 2
                dat = struct;
                if nargin < 1
                    opt = struct;
                end
            end
        end
    end
    cont = strcmpi(cont, 'continue');
    
    [opt, dat]        = pgra_model_input(opt, dat);
    opt               = pgra_model_default(opt);
    [opt, dat, model] = pgra_model_data(opt, dat, model);
    
    % -----------------------------------------------------------------
    %    Noise variance
    % -----------------------------------------------------------------
    switch lower(opt.model.name)
        case {'normal', 'gaussian', 'l2'}
            nc = size(dat(1).f, 4);
            [dat.sigma2] = deal(opt.model.sigma2);
            opt.model.sigma2 = zeros(1, nc);
            fprintf('%10s | %10s | [ ', 'Noise', 'Normal');
            for k=1:nc
                sig = 0;
                c   = 0;
                for n=1:opt.N
                    f   = single(dat(n).f(:,:,:,k));
                    msk = isfinite(f) & f > 0;
                    [h,x] = hist(f(msk), 64);
                    clear f msk
                    [~, ~, s] = spm_rice_mixture(h, x, 2);
                    if isfinite(s(1))
                        dat(n).sigma2(k) = s(1);
                        sig = sig + s(1);
                        c = c + 1;
                    else
                        [~, ~, s] = spm_rice_mixture(h, x, 1);
                        if isfinite(s)
                            dat(n).sigma2(k) = s;
                            sig = sig + s;
                            c = c + 1;
                        else
                            dat(n).sigma2 = inf;
                        end
                    end
                end
                opt.model.sigma2(k) = sig/c;
                fprintf('%6g ', opt.model.sigma2(k));
                for n=1:opt.N
                    if ~isfinite(dat(n).sigma2)
                        dat(n).sigma2(k) = opt.model.sigma2(k);
                    end
                end
            end
            fprintf(']\n');
    end
    
    % ---------------------------------------------------------------------
    %    Initialise all variables
    % ---------------------------------------------------------------------
    if ~cont
        if opt.verbose
            fprintf(['%10s | %10s | ' repmat('=',1,50) ' |\n'], 'EM', 'Init');
        end
        [dat, model] = initAll(dat, model, opt);
    end
    
    % -----------
    % Lower bound
    model      = plotAll(model, opt, 'loop');
    % -----------
    
    % ---------------------------------------------------------------------
    %    Variable factors
    % ---------------------------------------------------------------------
    % Armijo factor for Subspace line search
    % Because we don't factor part of the log-likelihood when computing the
    % gradient and hessian (in particular, log determinants), it is
    % necessary to check that we don't overshoot. Additionnaly, we try to
    % guess by how much we will overshoot based on the previous EM 
    % iteration.
    model.armijo = opt.armijo;
    % In our model RegZ = wpz1 * Az + wpz2 * W'LW
    % We allow to start with higher or lower weights, and to only use the
    % final weights for the lasts iterations.
    wpzscl1 = logspace(log10(opt.wpz0(1)/opt.wpz(1)), log10(1), opt.emit);
    wpzscl2 = logspace(log10(opt.wpz0(2)/opt.wpz(2)), log10(1), opt.emit);
    % We are going to activate the model components hierarchically, from
    % the least dimensional to the more dimensional:
    % >> affine -> PG -> residual field
    % The next component is automatically activated when the lower bound
    % converges
    lbthreshold = 1e-4;
    activated = struct('affine', true, 'pg', false, 'residual', false);
    
    % ---------------------------------------------------------------------
    %    EM iterations
    % ---------------------------------------------------------------------
    for emit = 1:opt.emit
    
        if opt.verbose
            fprintf(['%10s | %10d | ' repmat('=',1,50) ' |\n'], 'EM', emit);
        end
        
        if model.lbgain < lbthreshold
            if ~activated.affine
                activated.affine = true;
                opt.fwhm = 0.5 * opt.fwhm;
                fprintf('%10s | %10s\n', 'Activate', 'Affine');
            elseif ~activated.pg
                activated.pg = true;
                opt.fwhm = 0.5 * opt.fwhm;
                fprintf('%10s | %10s\n', 'Activate', 'PG');
            elseif ~activated.residual
                activated.residual = true;
                opt.fwhm = 0.5 * opt.fwhm;
                fprintf('%10s | %10s\n', 'Activate', 'Residual');
            else
                fprintf('%10s |\n', 'Converged');
                break
            end
        end
        
        % Update weights on precision Z
        model.wpz(1) = opt.wpz(1) * wpzscl1(emit);
        model.wpz(2) = opt.wpz(2) * wpzscl2(emit);
        model.regz   = model.wpz(1) * model.Az + model.wpz(2) * model.ww;
        
        % -----------------------------------------------------------------
        %    Affine
        % -----------------------------------------------------------------
        
        if activated.affine
        
            % Update parameters
            % -----------------
            [dat, model] = batchProcess('FitAffine', dat, model, opt);

            % Update prior
            % ------------
            rind = opt.affine_rind;
            model.Aq = precisionWishart(opt.nq0, model.qq(rind,rind) + model.Sq(rind,rind), opt.N);
            model.regq = model.Aq;

            % -----------
            % Lower bound
            model.lbaq = lbPrecisionMatrix(model.Aq, opt.N, opt.nq0);
            model.lbq  = lbAffine(dat, model, opt);
            model      = plotAll(model, opt);
            % -----------
            
        end
        
        % -----------------------------------------------------------------
        %    Principal subspace
        % -----------------------------------------------------------------

        if activated.pg
        
            [dat, model] = batchProcess('GradHessSubspace', dat, model, opt);

            % Factor of the prior : ln p(z|W) + ln p(W)
            % -------------------
            reg = model.wpz(2) * (model.zz + model.Sz) + eye(size(model.zz));

            % Gradient
            % --------
            for k=1:opt.K
                lw = spm_diffeo('vel2mom', single(model.w(:,:,:,:,k)), [opt.vs, opt.prm]);
                model.gw(:,:,:,:,k) = model.gw(:,:,:,:,k) + reg(k,k) * lw;
            end

            % Search direction
            % ----------------
            model.dw = prepareOnDisk(model.dw, size(model.w));
            for k=1:opt.K
                model.dw(:,:,:,:,k) = -spm_diffeo('fmg', ...
                    single(model.hw(:,:,:,:,k)), single(model.gw(:,:,:,:,k)), ...
                    double([opt.vs reg(k,k) * opt.prm 2 2]));
            end
            model.gw = rmarray(model.gw);
            model.hw = rmarray(model.hw);

            [~, model, dat] = lsSubspace(model.dw, model, dat, opt);

            model.regz = model.wpz(1) * model.Az + model.wpz(2) * model.ww;

            % -----------
            % Lower bound
            model.llw  = llPriorSubspace(model.w, model.ww, opt.vs, opt.prm);
            model.lbz  = lbLatent(dat, model, opt);
            model      = plotAll(model, opt);
            % -----------
            
        end
        
        % -----------------------------------------------------------------
        %    Latent coordinates
        % -----------------------------------------------------------------
        
        if activated.pg
        
            % Update q(z)
            % -----------
            [dat, model] = batchProcess('FitLatent', dat, model, opt);

            % -----------
            % Lower bound
            model.lbz = lbLatent(dat, model, opt);
            model     = plotAll(model, opt);
            % -----------

            % Orthogonalise
            % -------------
            if opt.verbose, fprintf('%10s | %10s ', 'Ortho', ''); tic; end;
            [U, iU] = orthogonalisationMatrix(model.zz, model.ww);
            if opt.verbose, fprintf('| %6gs\n', toc); end;

            % Rescale
            % -------
            if opt.verbose, fprintf('%10s | %10s ', 'Rescale', ''); tic; end;
            ezz = U*(model.zz + model.Sz)*U';
            if opt.nz0 == 0
                [Q, iQ] = scalePG(opt.N, opt.K);
            else
                [Q, iQ] = gnScalePG(ezz, opt.nz0, opt.N, model.wpz(2));
            end
            if opt.verbose, fprintf('| %6gs\n', toc); end;
            Q = Q*U;
            iQ = iU*iQ;
            [model, dat] = rotateAll(model, dat, opt, Q, iQ);
            model.Az = precisionWishart(opt.nz0, model.zz + model.Sz, opt.N);

            model.regz = model.wpz(1) * model.Az + model.wpz(2) * model.ww;

            % -----------
            % Lower bound
            model.llw  = llPriorSubspace(model.w, model.ww, opt.vs, opt.prm);
            model.lbaz = lbPrecisionMatrix(model.Az, opt.N, opt.nz0);
            model.lbz  = lbLatent(dat, model, opt);
            model      = plotAll(model, opt);
            % -----------
            
        end
        
        % -----------------------------------------------------------------
        %    Residual field
        % -----------------------------------------------------------------
        
        if activated.residual
        
            % Update subjects
            % ---------------
            [dat, model] = batchProcess('FitResidual', dat, model, opt);

            % -----------
            % Lower bound
            model.lbr = 0;
            for n=1:opt.N
                model.lbr = model.lbr - dat(n).klr;
            end
            model = plotAll(model, opt);
            % -----------
            
            % Update precision
            % ----------------
            model.lambda_prev = model.lambda;
            model.lambda = precisionResidualGamma(opt.lambda0, opt.nlam0, ...
                model.err, opt.N, opt.lat);
            if opt.verbose, fprintf('%10s | %10g\n', 'Lambda', model.lambda); end;
                
            % -----------
            % Lower bound
            dat = batchProcess('Update', dat, model, opt, {'klru'});
            model.lbr = 0;
            for n=1:opt.N
                model.lbr = model.lbr - dat(n).klr;
            end
            model.lbl  = lbPrecisionResidual(model.lambda, opt.N, ...
                            opt.nlam0, opt.lambda0, opt.lat);
            model      = plotAll(model, opt);
            % -----------
            
        end
        
        % -----------------------------------------------------------------
        %    Template
        % -----------------------------------------------------------------
        if opt.verbose, fprintf('%10s | %10s ', 'Template', ''); tic; end;
        if opt.tpm
            model.a = updateMuML(opt.model, dat, 'fwhm', opt.fwhm, ...
                                 'par', opt.par, 'debug', opt.debug, ...
                                 'output', model.a);
            model.gmu = templateGrad(model.a, opt.itrp, opt.bnd, ...
                'debug', opt.debug, 'output', model.gmu);
            model.mu = reconstructProbaTemplate(model.a, ...
                'loop', '', 'par', opt.par, 'debug', opt.debug, ...
                'output', model.mu);
        else
            model.mu = updateMuML(opt.model, dat, 'fwhm', opt.fwhm, ...
                                  'par', opt.par, 'debug', opt.debug, ...
                                  'output', model.mu);
            model.gmu = templateGrad(model.mu, opt.itrp, opt.bnd, ...
                'debug', opt.debug, 'output', model.gmu);
        end
        if opt.verbose, fprintf('| %6gs\n', toc); end;
        
        % -----------
        % Lower bound
        dat = batchProcess('Update', dat, model, opt, 'llm');
        model.llm = 0;
        for n=1:opt.N
            model.llm = model.llm + dat(n).llm;
        end
        model     = plotAll(model, opt, 'loop');
        % -----------
        
        save(fullfile(opt.directory, opt.fnames.result), 'model', 'dat', 'opt');
        
    end % < EM loop
    
end

% =========================================================================

function model = plotAll(model, opt, loop)

    if nargin < 3
        loop = false;
    else
        loop = strcmpi(loop, 'loop');
    end

    % Lower bound stuff
    % -----------------
    
    lb = 0;
    if isfield(model, 'llm')
        if ~isfield(model, 'savellm')
            model.savellm = [];
        end
        model.savellm = [model.savellm model.llm];
        lb = lb + model.llm;
    end
    if isfield(model, 'llw')
        if ~isfield(model, 'savellw')
            model.savellw = [];
        end
        model.savellw = [model.savellw model.llw];
        lb = lb + model.llw;
    end
    if isfield(model, 'lbr')
        if ~isfield(model, 'savelbr')
            model.savelbr = [];
        end
        model.savelbr = [model.savelbr model.lbr];
        lb = lb + model.lbr;
    end
    if isfield(model, 'lls')
        if ~isfield(model, 'savells')
            model.savells = [];
        end
        model.savells = [model.savells model.lls];
        lb = lb + model.lls;
    end
    if isfield(model, 'lbz')
        if ~isfield(model, 'savelbz')
            model.savelbz = [];
        end
        model.savelbz = [model.savelbz model.lbz];
        lb = lb + model.lbz;
    end
    if isfield(model, 'lbl')
        if ~isfield(model, 'savelbl')
            model.savelbl = [];
        end
        model.savelbl = [model.savelbl model.lbl];
        lb = lb + model.lbl;
    end
    if isfield(model, 'lbaz')
        if ~isfield(model, 'savelbaz')
            model.savelbaz = [];
        end
        model.savelbaz = [model.savelbaz model.lbaz];
        lb = lb + model.lbaz;
    end
    if isfield(model, 'lbq')
        if ~isfield(model, 'savelbq')
            model.savelbq = [];
        end
        model.savelbq = [model.savelbq model.lbq];
        lb = lb + model.lbq;
    end
    if isfield(model, 'lbaq')
        if ~isfield(model, 'savelbaq')
            model.savelbaq = [];
        end
        model.savelbaq = [model.savelbaq model.lbaq];
        lb = lb + model.lbaq;
    end
    if ~isfield(model, 'lb')
        model.lb = [];
    end
    model.lb = [model.lb lb];

    if ~isfield(model, 'lbdiff')
        model.lbdiff = inf;
    end
    if length(model.lb) > 1
        model.lbdiff = model.lb(end) - model.lb(end-1);
    end
    if loop
        if ~isfield(model, 'lblastloop')
            model.lblastloop = inf;
        end
        if ~isfield(model, 'lbgain')
            model.lbgain = inf;
        end
        if isfinite(model.lblastloop)
            model.lbgain = abs((model.lb(end) - model.lblastloop) / model.lblastloop);
        end
        model.lblastloop = model.lb(end);
    end
    
    if opt.verbose
        
        px = 4;
        py = 3;
        clf
        
        % Plot
        % ----
        vs = sqrt(sum(model.Mmu(1:3,1:3).^2));
        
        % Template & PG
        subplot(px, py, 1)
        tpl = catToColor(model.mu(:,:,ceil(size(model.mu,3)/2),:));
        dim = [size(tpl) 1 1];
        image(reshape(tpl, [dim(1:2) dim(4)]));
        daspect(1./vs);
        axis off
        title('template')
        subplot(px, py, 2)
        pg = defToColor(model.w(:,:,ceil(size(model.mu,3)/2),:,1));
        dim = [size(pg) 1 1];
        image(reshape(pg, [dim(1:2) dim(4)]));
        daspect(1./vs);
        axis off
        title('PG1 y')
        % Precision
        subplot(px, py, 4)
        imagesc(model.ww)
        daspect([1 1 1])
        colorbar
        title('E*[W''LW]')
        subplot(px, py, 5)
        imagesc(model.Az)
        daspect([1 1 1])
        colorbar
        title('E*[A]')
        % Lower bound
        if isfield(model, 'lb')
            subplot(px, py, 3)
            plot(model.lb)
            title('Lower bound')
        end
        if isfield(model, 'llm')
            subplot(px, py, 6)
            plot(model.savellm, 'r-')
            title('Data likelihood')
        end
        if isfield(model, 'llw')
            subplot(px, py, 7)
            plot(model.savellw, 'g-')
            title('Subspace prior')
        end
        if isfield(model, 'lbz')
            subplot(px, py, 8)
            plot(model.savelbz, 'k-')
            title('-KL Latent coord')
        end
        if isfield(model, 'lbl')
            subplot(px, py, 9)
            plot(model.savelbl, 'c-')
            title('-KL Residual precision')
        end
        if isfield(model, 'lbq')
            subplot(px, py, 10)
            plot(model.savelbq, 'b-')
            title('-KL Affine coord')
        end
        if isfield(model, 'lbaq')
            subplot(px, py, 11)
            plot(model.savelbaq, 'r-')
            title('-KL Affine precision')
        end
        if isfield(model, 'lbr')
            subplot(px, py, 12)
            plot(model.savelbr, 'g-')
            title('-KL Residual field')
        end
        
        drawnow
        
        % Print
        % -----
        
        fprintf('%10s | ', 'LB');
        if length(model.lb) > 1
            if model.lbdiff > 0
                fprintf('%10s | ', '(+)');
            elseif model.lbdiff < 0
                fprintf('%10s | ', '(-)');
            else
                fprintf('%10s | ', '(=)');
            end
        else
            fprintf('%10s | ', '');
        end
        fprintf(' %6g', model.lb(end));
        if loop
            fprintf([repmat(' ', 1, 37) ' | %6e'], model.lbgain);
        end
        fprintf('\n')
    end
end

function [dat, model] = initAll(dat, model, opt)

    % Init identity transforms
    % ------------------------
    
    % --- Zero init of Q (Affine)
    [dat, model] = batchProcess('InitAffine', 'zero', dat, model, opt);
    model.Aq   = eye(numel(opt.affine_rind));
    model.regq = model.Aq;
    
    % --- Zero init of R (Residual)
    model.lambda = opt.lambda0;
    model.lambda_prev = model.lambda;
    [dat, model] = batchProcess('InitResidual', 'zero', dat, model, opt);
    
    % --- Zero init of W (Principal geodesic)
    if ~checkarray(model.w)
        model.w = initSubspace(opt.lat, opt.K, 'type', 'zero', ...
            'debug', opt.debug, 'output', model.w);
    end
    if ~checkarray(model.ww)
        model.ww = zeros(opt.K);
    end
    
    % --- Zero init of Z (Latent coordinates)
    [dat, model] = batchProcess('InitLatent', 'zero', dat, model, opt);
    
    % --- Init of subject specific arrays
    dat = batchProcess('Update', dat, model, opt, ...
        {'v', 'ipsi', 'iphi', 'pf', 'c'}, 'clean', {'ipsi', 'iphi'});
    
    % --- Init template + Compute template spatial gradients + Build TPMs
    if opt.tpm
        model.a = updateMuML(opt.model, dat, 'fwhm', opt.fwhm, ...
                             'par', opt.par, 'debug', opt.debug, ...
                             'output', model.a);
        model.gmu = templateGrad(model.a, opt.itrp, opt.bnd, ...
            'debug', opt.debug, 'output', model.gmu);
        model.mu = reconstructProbaTemplate(model.a, ...
            'loop', '', 'par', opt.par, 'debug', opt.debug, ...
            'output', model.mu);
    else
        model.mu = updateMuML(opt.model, dat, 'fwhm', opt.fwhm, ...
                              'par', opt.par, 'debug', opt.debug, ...
                              'output', model.mu);
        model.gmu = templateGrad(model.mu, opt.itrp, opt.bnd, ...
            'debug', opt.debug, 'output', model.gmu);
    end
    
    % Init latent coordinates
    % -----------------------

    % --- Random init of E[z]
    [dat, model] = batchProcess('InitLatent', 'rand', dat, model, opt);

    % --- Orthogonalise sum{E[z]E[z]'}
    [U,S] = svd(model.zz);
    Rz    = 0.1*sqrt(opt.N/opt.K)*U/diag(sqrt(diag(S)+eps));
    dat   = batchProcess('RotateLatent', dat, opt, Rz');
    model.zz = Rz' * model.zz * Rz;
    model.Sz = Rz' * model.Sz * Rz;
    
    % --- Init precision of z
    model.Az   = eye(opt.K);
    model.regz = model.wpz(1) * model.Az;
    
    % Compute initial Lower Bound
    % ---------------------------
    dat = batchProcess('Update', dat, model, opt, {'wmu', 'llmw'});
    model.llm = 0;
    for n=1:opt.N
        model.llm = model.llm + dat(n).llm;
    end
    
    dat = batchProcess('Update', dat, model, opt, ...
            {'hz', 'Sz', 'hr', 'klr'}, 'clean', {'hz', 'hr'});
    model.lbr = 0;
    model.Sz = zeros(opt.K);
    for n=1:opt.N
        model.lbr = model.lbr - dat(n).klr;
        model.Sz = model.Sz + dat(n).Sz;
    end
    model.lbl  = lbPrecisionResidual(model.lambda, opt.N, ...
                    opt.nlam0, opt.lambda0, opt.lat);
    model.lbz  = lbLatent(dat, model, opt);
    model.lbaz = lbPrecisionMatrix(model.Az, opt.N, opt.nz0);
    ld = proba('LogDetDiffeo', opt.lat, sqrt(sum(model.Mmu(1:3,1:3).^2)), opt.prm);
    model.llw  = 0.5 * opt.K * (ld - prod(opt.lat)*3*log(2*pi));
    model.lbaq = lbPrecisionMatrix(model.Aq, opt.N, opt.nq0);
    model.lbq  = lbAffine(dat, model, opt);

end