
require("opt_precision")


local USE_DEPTH_CONSTRAINT 		= true
local USE_REGULARIZATION 		= true
local USE_SHADING_CONSTRAINT 	= true

local USE_J = false
local USE_PRECOMPUTE = true and not USE_J

local DEPTH_DISCONTINUITY_THRE = 0.01


local W,H 	= opt.Dim("W",0), opt.Dim("H",1)
local P 	= ad.ProblemSpec()

-- See TerraSolverParameters
local w_p						= P:Param("w_p",float,0)-- Is initialized by the solver!
local w_s		 				= P:Param("w_s",float,1)-- Regularization weight
local w_r						= P:Param("w_r",float,2)-- Prior weight
local w_g						= P:Param("w_g",float,3)-- Shading weight

w_p = ad.sqrt(w_p)
w_s = ad.sqrt(w_s)
w_r = ad.sqrt(w_r)
w_g = ad.sqrt(w_g)


local weightShadingStart		= P:Param("weightShadingStart",float,4)-- Starting value for incremental relaxation
local weightShadingIncrement	= P:Param("weightShadingIncrement",float,5)-- Update factor

local weightBoundary			= P:Param("weightBoundary",float,6)-- Boundary weight

local f_x						= P:Param("f_x",float,7)
local f_y						= P:Param("f_y",float,8)
local u_x 						= P:Param("u_x",float,9)
local u_y 						= P:Param("u_y",float,10)
    
local offset = 10;
local deltaTransform = {}
for i=1,16 do
	deltaTransform[i] = P:Param("deltaTransform_" .. i .. "",float,offset+i)
end
offset = offset + 16

local L = {}
for i=1,9 do
	L[i] = P:Param("L_" .. i .. "",float,offset+i)
end
offset = offset + 9
local nNonLinearIterations 	= P:Param("nNonLinearIterations",uint,offset+1) -- Steps of the non-linear solver	
local nLinIterations 		= P:Param("nLinIterations",uint,offset+2) -- Steps of the linear solver
local nPatchIterations 		= P:Param("nPatchIterations",uint,offset+3) -- Steps on linear step on block level
offset = offset + 4
local X     = P:Unknown("X",opt_float, {W,H},offset+0) -- Refined Depth
local D_i   = P:Image("D_i",opt_float, {W,H},offset+1) -- Depth input

local Im    = P:Image("Im",opt_float, {W,H},offset+2) -- Target Intensity
local D_p   = P:Image("D_p",opt_float, {W,H},offset+3) -- Previous Depth
local edgeMaskR = P:Image("edgeMaskR",uint8, {W,H},offset+4) -- Edge mask. 
local edgeMaskC = P:Image("edgeMaskC",uint8, {W,H},offset+5) -- Edge mask. 


local util = require("util")

local posX = ad.Index(0)
local posY = ad.Index(1)


function sqMagnitude(point) 
	return (point*point):sum()
end

-- equation 8
function p(offX,offY) 
    local d = X(offX,offY)
    local i = offX + posX
    local j = offY + posY
    return ad.Vector(((i-u_x)/f_x)*d, ((j-u_y)/f_y)*d, d)
end

-- equation 10
function normalAt(offX, offY)
	local i = offX + posX -- good
    local j = offY + posY -- good
    --f_x good, f_y good

    local n_x = X(offX, offY - 1) * (X(offX, offY) - X(offX - 1, offY)) / f_y
    local n_y = X(offX - 1, offY) * (X(offX, offY) - X(offX, offY - 1)) / f_x
    local n_z = (n_x * (u_x - i) / f_x) + (n_y * (u_y - j) / f_y) - (X(offX-1, offY)*X(offX, offY-1) / (f_x*f_y))
    local sqLength = n_x*n_x + n_y*n_y + n_z*n_z
    local inverseMagnitude = ad.select(ad.greater(sqLength, 0.0), 1.0/ad.sqrt(sqLength), 1.0)
    return inverseMagnitude * ad.Vector(n_x, n_y, n_z)
end

function B(offX, offY)
	local normal = normalAt(offX, offY)
	local n_x = normal[0]
	local n_y = normal[1]
	local n_z = normal[2]

	local lighting = L[1] +
					 L[2]*n_y + L[3]*n_z + L[4]*n_x  +
					 L[5]*n_x*n_y + L[6]*n_y*n_z + L[7]*(-n_x*n_x - n_y*n_y + 2*n_z*n_z) + L[8]*n_z*n_x + L[9]*(n_x*n_x-n_y*n_y)

	return 1.0*lighting -- replace 1.0 with estimated albedo in slower version
end

function I(offX, offY)
    -- TODO: WHYYYYYYYYYY?
	return Im(offX,offY)*0.5 + 0.25*(Im(offX-1,offY)+Im(offX,offY-1))
end

local function B_I(x,y)
    local bi = B(x,y) - I(x,y)
    local valid = ad.greater(D_i(x-1,y) + D_i(x,y) + D_i(x,y-1), 0)
    return ad.select(opt.InBoundsExpanded(0,0,1)*valid,bi,0)
end
if USE_PRECOMPUTE then
    B_I = P:ComputedImage("B_I",{W,H}, B_I(0,0))
end


local E_s = 0.0
local E_p = 0.0
local E_r_h = 0.0 
local E_r_v = 0.0 
local E_r_d = 0.0 
local E_g_v = 0.0
local E_g_h = 0.0
local pointValid = ad.greater(D_i(0,0), 0)

if USE_DEPTH_CONSTRAINT then
	local E_p_noCheck = X(0,0) - D_i(0,0)
	E_p = ad.select(opt.InBounds(0,0), ad.select(pointValid, E_p_noCheck, 0.0), 0.0)
end 

if USE_SHADING_CONSTRAINT then
    local BI00 = B_I(0,0)
    E_g_h = BI00 - B_I(1,0)
    E_g_v = BI00 - B_I(0,1)
    
    E_g_h = E_g_h * edgeMaskR(0,0)
	E_g_v = E_g_v * edgeMaskC(0,0)
	
	E_g_h = ad.select(opt.InBoundsExpanded(0,0,1), E_g_h, 0.0)
	E_g_v = ad.select(opt.InBoundsExpanded(0,0,1), E_g_v, 0.0)
end

local function allpositive(a,...)
    local r = ad.greater(a,0)
    for i = 1,select("#",...) do
        local e = select(i,...)
        r = ad.and_(r,ad.greater(e,0))
    end
    return r
end

if USE_REGULARIZATION then
	local cross_valid = allpositive(D_i(0,0), D_i(0,-1) , D_i(0,1) , D_i(-1,0) , D_i(1,0))
	local E_s_noCheck = 4.0*p(0,0) - (p(-1,0) + p(0,-1) + p(1,0) + p(0,1)) 
	
	local d = X(0,0)

	local E_s_guard =   ad.and_(ad.less(ad.abs(d - X(0,-1)), DEPTH_DISCONTINUITY_THRE), 
                            ad.and_(ad.less(ad.abs(d - X(0,1)), DEPTH_DISCONTINUITY_THRE), 
                                ad.and_(ad.less(ad.abs(d - X(-1,0)), DEPTH_DISCONTINUITY_THRE), 
                                    ad.and_(ad.less(ad.abs(d - X(1,0)), DEPTH_DISCONTINUITY_THRE), 
                                        ad.and_(opt.InBoundsExpanded(0,0,1), cross_valid)
                        ))))
    if USE_PRECOMPUTE then
        local guard = P:ComputedImage("E_s_guard", {W, H}, E_s_guard)                        
	    E_s_guard = ad.eq(guard(0,0),1)
	end
	
	E_s = ad.select(E_s_guard,E_s_noCheck,0)
end

if USE_J then
    E_g_h = P:ComputedImage("E_g_h", {W,H}, E_g_h)(0,0)
    E_g_v = P:ComputedImage("E_g_v", {W,H}, E_g_v)(0,0)
    E_s = P:ComputedImage("E_s", {W,H}, E_s)(0,0)
    E_p = P:ComputedImage("E_p", {W,H}, E_p)(0,0)
end

local cost = {w_g*E_g_h, w_g*E_g_v, w_s*E_s, w_p*E_p}
P:Exclude(ad.not_(ad.greater(D_i(0,0),0)))

return P:Cost(unpack(cost))

