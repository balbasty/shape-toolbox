function lb = lbLatent(dat, model, opt)
% FORMAT ll = lbLatent(dat, model, opt))
%
% Uses model: Az, N, K, zz, Sz
%        dat: z, S z
%        opt: nz0
%
% Part of the lower-bound encompassing latent coordinates terms
% > -KL(q||p) = E[ln p(z)] - E[ln q(z)]

    lb = 0;
    for n=1:opt.N
        if any(any(dat(n).Sz ~= 0))
            lb = lb - spm_matcomp('LogDet', dat(n).Sz);
        end
    end
    
    lb = lb + trace(model.zz * model.Az);
    lb = lb - opt.N * spm_matcomp('LogDet', model.Az);
    lb = lb - opt.N * size(model.Az,1) + trace(model.Sz * model.Az);
    
    lb = -0.5 * lb;
end