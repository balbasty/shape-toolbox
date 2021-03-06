function shape_fit(input,opt)
% FORMAT shape_fit(input,opt)
% input - Matlab structure or JSON file containing input filenames
% opt   - Matlab structure or JSON file containing option values
%
% Fit a shape model on new data. This is a wrapper around the
% `shape_model` function that can take JSON files as inputs and that can be
% compiled and used on command line.
%
% Both json should contain structured values (equivalent to a a maltab
% structure). Type `help shape_model` for details on these structures and
% their fields.
%
% A few shape_model options are overriden so that the model is in 'fit' 
% mode. In particular, optimise.pg, optimise.tpl, optimise.z.A, 
% optimise.v.l and optimise.q.A are all set to false (i.e., they are 
% fixed model parameters).

    % ---------------------------------------------------------------------
    % Read options
    if nargin > 1
        if ischar(opt)
            try
                opt = spm_jsonread(opt);
            catch
                error('Error reading the option JSON file')
            end
        elseif ~isstruct(opt)
            error('Argument `opt `should be either a Matlab structure or a JSON file')
        end
    else
        opt = struct;
    end
    
    % ---------------------------------------------------------------------
    % Read input files
    if nargin == 0 || (ischar(input) && ...
            (strcmp(input,'--help') || ...
             strcmp(input,'--h')    || ...
             strcmp(input,'-h')))
        show_instructions;
        return
    elseif ischar(input)
        try
            input = spm_jsonread(input);
        catch
            error('Error reading the input JSON file')
        end
    elseif ~isstruct(json_opt)
        error('Argument `input` should be either a Matlab structure or a JSON file')
    end
    
    % ---------------------------------------------------------------------
    % Check mandatory files
    if ~isfield(input, 'f')
        warning('A list of input files is mandatory ("f")');
        show_instructions;
        return
    end
    if ~isfield(input, 'w') || ~exist(input.w, 'file')
        warning('A principal subspace is mandatory ("w")');
        show_instructions;
        return
    end
    if (~isfield(input, 'a') || ~exist(input.a, 'file')) ...
            && (~isfield(input, 'mu') || ~exist(input.mu, 'file'))
        warning('A template is mandatory ("a" or "mu")');
        show_instructions;
        return
    end
    
    % ---------------------------------------------------------------------
    % Read some parameters from input files
    nii = nifti(input.w);
    K    = size(nii.dat, 5);
    prm = regexp(nii.descrip, 'Principal geodesic \(([^\(]*)\)', 'tokens');
    if ~isempty(prm) && ~isempty(prm{1})
        prm = num2str(prm{1}{1});
    else
        prm = [];
    end
    if isfield(input, 'a')
        nii = nifti(input.a);
    else
        nii = nifti(input.mu);
    end
    nc = size(nii.dat, 4);
    clear nii

    % ---------------------------------------------------------------------
    % Fix a few options
    opt.optimise.pg  = false;
    opt.optimise.tpl = false;
    if isfield(opt.optimise, 'z')
        if isstruct(opt.optimise.z)
            opt.optimise.z.A = false;
        else
            value = opt.optimise.z;
            opt.optimise.z = struct;
            opt.optimise.z.A = false;
            opt.optimise.z.z = value;
        end
    else
        opt.optimise.z.A = false;
    end
    if isfield(opt.optimise, 'q')
        if isstruct(opt.optimise.q)
            opt.optimise.q.A = false;
        else
            value = opt.optimise.q;
            opt.optimise.q = struct;
            opt.optimise.q.A = false;
            opt.optimise.q.q = value;
        end
    else
        opt.optimise.q.A = false;
    end
    if isfield(opt.optimise, 'v')
        if isstruct(opt.optimise.v)
            opt.optimise.v.l = false;
        else
            value = opt.optimise.v;
            opt.optimise.v = struct;
            opt.optimise.v.l = false;
            opt.optimise.v.r = value;
        end
    else
        opt.optimise.v.l = false;
    end
    opt.optimise.mixreg.w = false;
    opt.optimise.mixreg.a = false;
    opt.mixreg.a0         = 1;
    if isfield(opt, 'pg') && isfield(opt.pg, 'K')
        if opt.pg.K > K
            warning(['Asking for more principal modes than available. ' ...
                     'I will use %d instead.'], K);
            opt.pg.K = K;
        end
    else
        opt.pg.K = K;
    end
    if ~isfield(opt, 'pg') || ~isfield(opt.pg, 'prm')
        if isempty(prm)
            warning('Could not read regularisation from file. I will use a default value instead.')
        else
            opt.pg.prm = prm;
        end
    end
    opt.model.nc          = nc;
    
    % ---------------------------------------------------------------------
    % Convert input matrices
    if isfield(opt, 'z') && isfield(opt.z, 'A0')
        if ischar(opt.z.A0) && exist(opt.z.A0, 'file')
            opt.z.A0 = load(opt.z.A0);
        elseif isnumeric(opt.z.A0) && isvector(opt.z.A0)
            opt.z.A0 = diag(opt.z.A0);
        end
    end
    if isfield(opt, 'q') && isfield(opt.q, 'A0')
        if ischar(opt.q.A0) && exist(opt.q.A0, 'file')
            opt.q.A0 = load(opt.q.A0);
        elseif isnumeric(opt.q.A0) && isvector(opt.q.A0)
            opt.q.A0 = diag(opt.q.A0);
        end
    end
    
    % ---------------------------------------------------------------------
    % Run the algorithm
    shape_model(input,opt);
end

% Temporary help
function show_instructions
    descr_str = 'Apply a shape model to a set of 2D or 3D images';
    usg_str   = 'Usage: shape_fit input.json opt.json';
    cpr_str   = 'Copyright (C) 2018 Wellcome Centre for Human Neuroimaging';
    help_str  = ['' ...
'INPUT\n' ...
'-----\n' ...
'\n' ...
'The input structure should contain the key "f" associated to a list of \n' ...
'filenames (NIfTI or Analyze format) containing the observed images.\n' ...
'They can be binary, categorical or intensity images. If the list is \n' ...
'two-dimensional, the second dimension (i.e., the most nested one)\n' ...
'should contain different classes (or modalities) of the same subject.\n' ...
'\n' ...
'Additionally, the keys "w" and "mu" (''normal'' model) or "a"\n' ...
'(''categorical''/''bernoulli'' model) must contain the filenames of\n' ...
'learned parameters (usually, `subspace.nii` and `template.nii` or\n' ...
'`log_template.nii`).\n' ...
'\n' ...
'OPTIONS\n' ...
'-------\n' ...
'\n' ...
'Options take the form of a hierarchical dictionary. We provide\n' ...
'descriptions for the most useful ones using Matlab notations\n' ...
'(key1.key2 should be written {"k1":{"k2":value}} in JSON).\n' ...
'A complete list can be found in the online documentation or README file.\n' ...
'\n' ...
'"mandatory" options\n' ...
'-------------------\n' ...
'These options reflect parameters obtained during model learning and are\n' ...
'thus part of the model.\n' ...
'model.name   - Data type/model:      ''categorical''/''bernoulli''/[''normal'']\n' ...
'z.A0         - Latent precision matrix                         [identity]\n' ...
'v.l0         - Anatomical noise precision                      [17]\n' ...
'\n' ...
'"optional" options\n' ...
'------------------\n' ...
'f.M               - Force same voxel-to-world to all images         [from file]\n' ...
'lb.threshold      - Convergence criterion (lower bound gain)        [1e-3]\n' ...
'par.subjects.mode - Parallelise processing                 ''parfor''/[''for'']\n' ...
'ui.verbose        - Talk during processing                          [true]\n' ...
'ui.fig_pop        - Plot lower bound                                [true]\n' ...
'ui.fig_sub        - Plot a few subjects                             [true]\n' ...
'dir.model         - Directory where to store model data             [''.'']\n' ...
'dir.dat           - Directory where to store data arrays            [next to input]\n' ...
    ];
    fprintf([repmat('_',1,80) '\n']);
    fprintf('\n');
    fprintf([' ' descr_str '\n']);
    fprintf('\n');
    fprintf(['     ' usg_str '\n']);
    fprintf('\n');
    fprintf([repmat('-',1,80) '\n']);
    fprintf('\n');
    fprintf(help_str);
    fprintf('\n');
    fprintf([repmat('_',1,80) '\n']);
    fprintf([' ' cpr_str '\n']);
end