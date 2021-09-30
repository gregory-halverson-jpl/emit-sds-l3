"""
This code is designed to load in and manage a spectral library.

Written by: Philip G. Brodrick, philip.brodrick@jpl.nasa.gov
"""

using DataFrames
using CSV
using Interpolations
using Logging
using Statistics
using Plots

function nanargmax(input::Array)
    x = copy(input)
    x[isnan.(x)] .= -Inf;
    return argmax(x);
end

function nanargmin(input::Array)
    x = copy(input)
    x[isnan.(x)] .= Inf;
    return argmin(x);
end

function read_envi_wavelengths(filename::String)
    header_name = splitext(filename)[1] * ".hdr"
    header = readlines(header_name)
    found = false
    for line in header
        if occursin("wavelength = {", line) || occursin("wavelength= {", line) ||  occursin("wavelength={", line)
            header = line
            found = true
            break
        end
    end

    if !found
        @error "No wavelength found in " * header_name
        return nothing
    end

    wavelengths = [parse(Float64, strip(x)) for x in split(split(split(header, "{")[2], "}")[1],",")]
    return wavelengths
end

function get_good_bands_mask(wavelengths::Array{Float64}, wavelength_pairs)
    good_bands = ones(Bool, length(wavelengths))

    for wvp in wavelength_pairs
        wavelength_diff = wavelengths .- wvp[1]
        wavelength_diff[wavelength_diff .< 0] .= maximum(filter(!isnan, wavelength_diff))
        lower_index = nanargmin(wavelength_diff)

        wavelength_diff = wvp[2] .- wavelengths
        wavelength_diff[wavelength_diff .< 0] .= maximum(filter(!isnan, wavelength_diff))
        upper_index = nanargmin(wavelength_diff)
        good_bands[lower_index:upper_index] .= false
    end

    return good_bands
end

mutable struct SpectralLibrary
    file_name::String
    class_header_name::String
    spectral_starting_column::Int64
    class_valid_keys
    scale_factor::Float64
    wavelength_regions_ignore
    SpectralLibrary(file_name::String, class_header_name::String, spectral_starting_column::Int64, class_valid_keys = nothing, scale_factor = 1.0, wavelength_regions_ignore= [[0,440],[1310,1490],[1770,2050],[2440,2880]]) = new(file_name, class_header_name, spectral_starting_column, class_valid_keys, scale_factor, wavelength_regions_ignore)

    spectra
    classes
    good_bands
    wavelengths
end

function load_data!(library::SpectralLibrary)
    df = DataFrame(CSV.File(library.file_name))
    library.spectra = Matrix(df[:,library.spectral_starting_column:end])
    library.classes = convert(Array, df[!,library.class_header_name])
    library.wavelengths = parse.(Float64, names(df[:,library.spectral_starting_column:end]))

    wl_order = sortperm(library.wavelengths)
    library.spectra = library.spectra[:,wl_order]
    library.wavelengths = library.wavelengths[wl_order]

    if isnothing(library.class_valid_keys)
        library.class_valid_keys = unique(library.classes)
    end

    good_bands = get_good_bands_mask(library.wavelengths, library.wavelength_regions_ignore)
    library.good_bands = good_bands

    return library
end

function filter_by_class!(library::SpectralLibrary)
    if isnothing(library.class_valid_keys)
        @info "No class valid keys provided, no filtering occuring"
        return
    end

    valid_classes = zeros(Bool, size(library.spectra)[1])
    for cla in library.class_valid_keys
        valid_classes[library.classes .== cla] .= true
    end

    library.spectra = library.spectra[valid_classes,:]
    library.classes = library.classes[valid_classes]
end

function remove_wavelength_region_inplace!(library::SpectralLibrary, set_as_nans::Bool=false)
    if set_as_nans
        library.spectra[:,.!library.good_bands] .= NaN
        library.wavelengths[.!library.good_bands] .= NaN
    else
        library.spectra = library.spectra[:, library.good_bands]
        library.wavelengths = library.wavelengths[library.good_bands]
    end
end

function interpolate_library_to_new_wavelengths!(library::SpectralLibrary, new_wavelengths::Array{Float64})
    old_spectra = copy(library.spectra)

    library.spectra = zeros((size(library.spectra)[1], length(new_wavelengths)))
    for _s in 1:size(old_spectra)[1]
        fit = LinearInterpolation(library.wavelengths, old_spectra[_s,:], extrapolation_bc=Flat());
        library.spectra[_s,:] = fit(new_wavelengths)
    end
    library.wavelengths = new_wavelengths

    good_bands = get_good_bands_mask(library.wavelengths, library.wavelength_regions_ignore)
    library.good_bands = good_bands
end

function scale_library!(library::SpectralLibrary, scaling_factor=nothing)
    if isnothing(scaling_factor)
        library.spectra =  library.spectra ./ library.scale_factor
    else
        library.spectra /= scaling_factor
    end
end

function brightness_normalize!(library::SpectralLibrary)
    library.spectra = library.spectra ./ sqrt.(mean(library.spectra[:,library.good_bands].^2, dims=2))
end

function plot_mean_endmembers(endmember_library::SpectralLibrary, output_name::String)
    for (_u, u) in enumerate(endmember_library.class_valid_keys)
        mean_spectra = mean(endmember_library.spectra[endmember_library.classes .== u,:],dims=1)[:]
        if _u == 1
            plot(endmember_library.wavelengths, mean_spectra, label=u)
        else
            plot!(endmember_library.wavelengths, mean_spectra, label=u, xlim=[300,3200])
        end
    end
    xlabel!("Wavelength [nm]")
    ylabel!("Reflectance")
    xticks!([500, 1000, 1500, 2000, 2500, 3000])
    savefig(output_name)
end

function plot_endmembers(endmember_library::SpectralLibrary, output_name::String)

    for (_u, u) in enumerate(endmember_library.class_valid_keys)
        if _u == 1
            plot(endmember_library.wavelengths, endmember_library.spectra[endmember_library.classes .== u,:]', lab="", xlim=[300,3200], color=palette(:tab10)[_u],dpi=400)
        else
            plot!(endmember_library.wavelengths, endmember_library.spectra[endmember_library.classes .== u,:]', lab="",xlim=[300,3200], color=palette(:tab10)[_u])
        end
    end
    xlabel!("Wavelenth [nm]")
    ylabel!("Reflectance")
    xticks!([500, 1000, 1500, 2000, 2500, 3000])
    for (_u, u) in enumerate(endmember_library.class_valid_keys)
        plot!([1:2],[0,0.3], color=palette(:tab10)[_u], labels=u)
    end
    savefig(output_name)
end

function plot_endmembers_individually(endmember_library::SpectralLibrary, output_name::String)
    plots = []
    spectra = endmember_library.spectra
    classes = endmember_library.classes
    for (_u, u) in enumerate(endmember_library.class_valid_keys)
        sp = spectra[classes .== u,:]
        sp[broadcast(isnan,sp)] .= 0
        brightness = sum(sp, dims=2)
        toplot = spectra[classes .== u,:] ./ brightness
        #push!(plots, plot(endmember_library.wavelengths, toplot', title=u, color=palette(:tab10)[_u], xlabel="Wavelength [nm]", ylabel="Reflectance"))
        push!(plots, plot(endmember_library.wavelengths, toplot', title=u, xlabel="Wavelength [nm]", ylabel="Reflectance"))
        xticks!([500, 1000, 1500, 2000, 2500])
    end
    plot(plots...,size=(1000,600),dpi=400)
    savefig(output_name)
end